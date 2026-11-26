alter table amex_requisiciones.solicitudes
  add column pais_compra text check (pais_compra in ('USA','CHINA')),
  add column compra_iniciada_at timestamptz;

update amex_requisiciones.usuarios
set permisos=array_append(permisos, 'comprar_internacional')
where nombre='Paco' and activo and not ('comprar_internacional'=any(permisos));

update amex_requisiciones.usuarios
set permisos=array_append(permisos, 'seguimiento_internacional')
where nombre='Luis Fuentes' and activo and not ('seguimiento_internacional'=any(permisos));

create function amex_requisiciones.iniciar_compra_internacional(p_token uuid,p_id integer)
returns void language plpgsql security definer set search_path=''
as $$
declare
  ses jsonb := amex_req_priv.sesion(p_token);
  pedido amex_requisiciones.solicitudes%rowtype;
begin
  if not amex_req_priv.tiene(ses,'comprar_internacional') then raise exception 'Solo Compras internacionales puede iniciar este pedido'; end if;
  select * into pedido from amex_requisiciones.solicitudes
    where id=p_id and not borrado and tipo='internacional' for update;
  if not found or pedido.estatus<>'por_comprar' then raise exception 'El pedido no está listo para iniciar compra internacional'; end if;
  if pedido.compra_iniciada_at is not null then return; end if;
  if pedido.pais_compra is null then raise exception 'Selecciona el país en Comprar antes de iniciar el seguimiento'; end if;
  update amex_requisiciones.solicitudes set compra_iniciada_at=now(), comprador_nombre=ses->>'nombre', updated_at=now() where id=p_id;
  perform amex_req_priv.log(p_id,ses->>'nombre','inició compra internacional',pedido.pais_compra);
end;
$$;
revoke all on function amex_requisiciones.iniciar_compra_internacional(uuid,integer) from public, authenticated;
grant execute on function amex_requisiciones.iniciar_compra_internacional(uuid,integer) to anon;

CREATE OR REPLACE FUNCTION amex_requisiciones.crear_solicitud(p_token uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); v_id int; v_usd numeric; v_folio text; v_pais text := nullif(p->>'pais_compra','');
begin
  if not amex_req_priv.tiene(s,'solicitar') then raise exception 'Sin permiso para solicitar'; end if;
  if coalesce(trim(p->>'osen'),'') = '' then raise exception 'La OSEN es obligatoria'; end if;
  if nullif(p->>'fecha_requerida','') is null then raise exception 'Indica la fecha requerida'; end if;
  if nullif(p->>'fecha_tentativa','') is null then raise exception 'Indica la fecha tentativa de llegada'; end if;
  if jsonb_array_length(coalesce(p->'partidas','[]')) = 0 then raise exception 'Agrega al menos una partida'; end if;
  if v_pais is not null and v_pais not in ('USA','CHINA') then raise exception 'Selecciona USA o China'; end if;
  insert into solicitudes(empresa, osen, prioridad, fecha_requerida, fecha_tentativa, solicita_id, solicita_nombre, notas, tipo, pais_compra, tc)
  values (coalesce(nullif(p->>'empresa',''),'Liumaq'), upper(trim(p->>'osen')), coalesce(nullif(p->>'prioridad',''),'normal'),
          nullif(p->>'fecha_requerida','')::date, nullif(p->>'fecha_tentativa','')::date, (s->>'id')::int, s->>'nombre', p->>'notas', case when v_pais is not null then 'internacional' else 'local' end, v_pais,
          (select valor from amex_req_priv.tipo_cambio_vigente()))
  returning id, folio into v_id, v_folio;
  perform amex_req_priv.insertar_partidas(v_id, p->'partidas');
  perform amex_req_priv.recalcular(v_id);
  select total_usd into v_usd from solicitudes where id = v_id;
  if v_usd > (select value::numeric from config where key='umbral_aprobacion_usd') then
    update solicitudes set estatus = 'por_aprobar' where id = v_id; end if;
  perform amex_req_priv.log(v_id, s->>'nombre', 'creó', null);
  return jsonb_build_object('id', v_id, 'folio', v_folio);
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.listar_solicitudes(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); solo_mias boolean;
begin
  solo_mias := not (amex_req_priv.tiene(s,'comprar') or amex_req_priv.tiene(s,'comprar_local') or amex_req_priv.tiene(s,'recibir')
                    or amex_req_priv.tiene(s,'aprobar') or amex_req_priv.tiene(s,'consulta'));
  return coalesce((
    select jsonb_agg(to_jsonb(so) || jsonb_build_object(
      'partidas', coalesce((select jsonb_agg(to_jsonb(pa) order by pa.id) from partidas pa where pa.solicitud_id = so.id and not pa.borrado),'[]'),
      'eventos', coalesce((select jsonb_agg(to_jsonb(e) order by e.id) from solicitud_eventos e where e.solicitud_id = so.id),'[]'))
      order by so.created_at desc)
    from solicitudes so
    where not so.borrado and (
      so.solicita_id=(s->>'id')::int or amex_req_priv.tiene(s,'admin') or
      (coalesce(so.tipo,'local')<>'internacional' and not solo_mias) or
      (so.tipo='internacional' and (
        amex_req_priv.tiene(s,'comprar_internacional') or
        (amex_req_priv.tiene(s,'seguimiento_internacional') and so.compra_iniciada_at is not null) or
        (amex_req_priv.tiene(s,'aprobar') and so.estatus='por_aprobar') or
        (amex_req_priv.tiene(s,'recibir') and so.estatus in ('comprado','en_transito','parcial'))
      ))
    )), '[]');
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.actualizar_compra(p_token uuid, p_id integer, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); so record; x jsonb; v_tipo text; v_llegada date; v_pais text;
begin
  select * into so from solicitudes where id = p_id and not borrado for update;
  if not found then raise exception 'No existe'; end if;
  v_tipo := coalesce(nullif(p->>'tipo',''), so.tipo);
  if so.tipo='internacional' or v_tipo='internacional' then
    if not amex_req_priv.tiene(s,'comprar_internacional') then raise exception 'Sin permiso para compras internacionales'; end if;
    if v_tipo is distinct from 'internacional' then raise exception 'Una compra internacional no puede cambiar a local desde Compras'; end if;
    v_pais := coalesce(nullif(p->>'pais_compra',''),so.pais_compra);
    if v_pais is null or v_pais not in ('USA','CHINA') then raise exception 'Selecciona USA o China'; end if;
  elsif not (amex_req_priv.tiene(s,'comprar') or (amex_req_priv.tiene(s,'comprar_local') and v_tipo='local')) then
    raise exception 'Sin permiso para comprar este pedido';
  end if;
  if so.estatus in ('por_aprobar','rechazada') and not amex_req_priv.tiene(s,'admin') then
    raise exception 'Este pedido requiere aprobación de Gabriel'; end if;
  if so.estatus not in ('por_comprar','comprado','en_transito') then
    raise exception 'Este pedido no está en la etapa de compras'; end if;
  if nullif(p->>'estatus','') is not null and p->>'estatus' not in ('por_comprar','comprado','en_transito','cancelada') then
    raise exception 'Estatus inválido para compras'; end if;
  v_llegada := case when p ? 'fecha_tentativa' then nullif(p->>'fecha_tentativa','')::date else so.fecha_tentativa end;
  if coalesce(nullif(p->>'estatus',''),so.estatus) in ('comprado','en_transito') and v_llegada is null then
    raise exception 'Indica la fecha tentativa de llegada a almacén'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'partidas','[]')) loop
    update partidas set precio = coalesce(nullif(x->>'precio','')::numeric, precio),
                        moneda = coalesce(nullif(upper(x->>'moneda'),''), moneda)
    where id = (x->>'id')::int and solicitud_id = p_id;
  end loop;
  update solicitudes set tipo = v_tipo, pais_compra=v_pais,
    compra_iniciada_at=case when v_tipo='internacional' then coalesce(compra_iniciada_at,now()) else compra_iniciada_at end,
    proveedor = coalesce(p->>'proveedor', proveedor),
    estatus = coalesce(nullif(p->>'estatus',''), estatus), fecha_tentativa = v_llegada, comprador_nombre = s->>'nombre', updated_at = now()
  where id = p_id;
  perform amex_req_priv.recalcular(p_id);
  update solicitudes set estatus = 'por_aprobar' where id = p_id and aprobado_por is null
    and total_usd > (select value::numeric from config where key='umbral_aprobacion_usd');
  perform amex_req_priv.log(p_id, s->>'nombre', 'actualizó compra', p->>'estatus');
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.avisos_internos(p_token uuid, p_leidos bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  ses jsonb := amex_req_priv.sesion(p_token);
  persona integer := coalesce((ses->>'id')::integer, 0);
  avisos jsonb;
begin
  if cardinality(p_leidos) > 100 then raise exception 'Demasiados avisos'; end if;

  with visibles as materialized (
    select e.id as evento, s.id, s.folio, s.osen, e.estatus, e.creado
    from amex_req_priv.avisos_eventos e
    join amex_requisiciones.solicitudes s on s.id = e.solicitud_id
    where not s.borrado and (
      s.solicita_id = persona or (
        e.estatus = s.estatus and (
          (e.estatus = 'por_aprobar' and amex_req_priv.tiene(ses, 'aprobar'))
          or (e.estatus = 'por_comprar' and (
            (s.tipo='internacional' and amex_req_priv.tiene(ses,'comprar_internacional'))
            or (coalesce(s.tipo,'local')='local' and (amex_req_priv.tiene(ses,'comprar') or amex_req_priv.tiene(ses,'comprar_local')))
          ))
          or (e.estatus in ('comprado','en_transito','parcial') and amex_req_priv.tiene(ses, 'recibir'))
        )
        and not exists (
          select 1 from amex_req_priv.avisos_eventos posterior
          where posterior.solicitud_id = e.solicitud_id and posterior.id > e.id
        )
      )
    )
    order by e.id desc limit 100
  ), marcados as (
    insert into amex_req_priv.avisos_leidos(usuario,aviso)
    select persona, evento from visibles where evento = any(p_leidos)
    on conflict do nothing
    returning aviso
  )
  select coalesce(jsonb_agg(to_jsonb(v) || jsonb_build_object('leido',
    l.aviso is not null or m.aviso is not null) order by v.evento desc), '[]'::jsonb)
  into avisos from visibles v
  left join amex_req_priv.avisos_leidos l on l.usuario = persona and l.aviso = v.evento
  left join marcados m on m.aviso = v.evento;
  return avisos;
end;
$function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.editar_solicitud_propia(p_token uuid, p_id integer, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  ses jsonb := amex_req_priv.sesion(p_token);
  pedido amex_requisiciones.solicitudes%rowtype;
  fecha date := nullif(p->>'fecha_requerida','')::date;
  tentativa date := nullif(p->>'fecha_tentativa','')::date;
  umbral numeric;
begin
  if not amex_req_priv.tiene(ses,'solicitar') then
    raise exception 'Sin permiso para editar solicitudes';
  end if;
  select * into pedido from amex_requisiciones.solicitudes
    where id=p_id and solicita_id=(ses->>'id')::integer and not borrado for update;
  if not found then raise exception 'Solo puedes editar solicitudes propias'; end if;
  if pedido.estatus not in ('por_aprobar','por_comprar','comprado','en_transito','parcial') then
    raise exception 'El pedido ya está cerrado'; end if;
  if pedido.updated_at is distinct from (p->>'actualizado')::timestamptz then
    raise exception 'El pedido cambió. Cierra y abre el editor para ver la versión actual'; end if;
  if coalesce(trim(p->>'osen'),'')='' then raise exception 'La OSEN es obligatoria'; end if;
  if fecha is null then raise exception 'Indica la fecha requerida'; end if;
  if tentativa is null then raise exception 'Indica la fecha tentativa de llegada'; end if;
  if coalesce(p->>'prioridad','') not in ('normal','urgente') then raise exception 'Prioridad inválida'; end if;

  if p ? 'partidas' then
    if pedido.estatus not in ('por_aprobar','por_comprar') or pedido.compra_iniciada_at is not null then
      raise exception 'La compra ya está en proceso; las partidas las debe corregir Admin'; end if;
    if coalesce(p->>'empresa','') not in ('Liumaq','AMEX Machinery') then raise exception 'Empresa inválida'; end if;
    if jsonb_array_length(p->'partidas')=0 then raise exception 'Agrega al menos una partida'; end if;
    if exists (
      select 1 from jsonb_array_elements(p->'partidas') partida
      where coalesce(trim(partida->>'descripcion'),'')=''
        or coalesce(nullif(partida->>'cantidad','')::numeric,0)<=0
        or coalesce(nullif(partida->>'precio','')::numeric,0)<0
        or coalesce(partida->>'moneda','') not in ('MXN','USD')
    ) then raise exception 'Revisa las partidas y sus cantidades'; end if;

    update amex_requisiciones.solicitudes set empresa=p->>'empresa', aprobado_por=null,
      aprobado_at=null, comentario_aprobacion=null
    where id=p_id;
    update amex_requisiciones.partidas set borrado=true where solicitud_id=p_id and not borrado;
    perform amex_req_priv.insertar_partidas(p_id,p->'partidas');
    perform amex_req_priv.recalcular(p_id);
    select value::numeric into strict umbral from amex_requisiciones.config where key='umbral_aprobacion_usd';
    update amex_requisiciones.solicitudes set estatus=(case when total_usd>umbral then 'por_aprobar' else 'por_comprar' end)
    where id=p_id;
  end if;

  update amex_requisiciones.solicitudes set osen=upper(trim(p->>'osen')),
    fecha_requerida=fecha, fecha_tentativa=tentativa, prioridad=p->>'prioridad',
    notas=p->>'notas', updated_at=clock_timestamp()
  where id=p_id;
  perform amex_req_priv.log(p_id,ses->>'nombre','editó su solicitud',null);
end;
$function$;

notify pgrst, 'reload schema';
