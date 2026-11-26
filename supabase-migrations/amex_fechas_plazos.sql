alter table amex_requisiciones.solicitudes add column fecha_tentativa date;

CREATE OR REPLACE FUNCTION amex_requisiciones.crear_solicitud(p_token uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); v_id int; v_usd numeric; v_folio text;
begin
  if not amex_req_priv.tiene(s,'solicitar') then raise exception 'Sin permiso para solicitar'; end if;
  if coalesce(trim(p->>'osen'),'') = '' then raise exception 'La OSEN es obligatoria'; end if;
  if nullif(p->>'fecha_requerida','') is null then raise exception 'Indica la fecha requerida'; end if;
  if jsonb_array_length(coalesce(p->'partidas','[]')) = 0 then raise exception 'Agrega al menos una partida'; end if;
  insert into solicitudes(empresa, osen, prioridad, fecha_requerida, solicita_id, solicita_nombre, notas, tc)
  values (coalesce(nullif(p->>'empresa',''),'Liumaq'), upper(trim(p->>'osen')), coalesce(nullif(p->>'prioridad',''),'normal'),
          nullif(p->>'fecha_requerida','')::date, (s->>'id')::int, s->>'nombre', p->>'notas',
          (select valor from tipo_cambio order by fecha desc limit 1))
  returning id, folio into v_id, v_folio;
  perform amex_req_priv.insertar_partidas(v_id, p->'partidas');
  perform amex_req_priv.recalcular(v_id);
  select total_usd into v_usd from solicitudes where id = v_id;
  if v_usd > (select value::numeric from config where key='umbral_aprobacion_usd') then
    update solicitudes set estatus = 'por_aprobar' where id = v_id; end if;
  perform amex_req_priv.log(v_id, s->>'nombre', 'creó', null);
  return jsonb_build_object('id', v_id, 'folio', v_folio);
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.actualizar_compra(p_token uuid, p_id integer, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); so record; x jsonb; v_tipo text; v_llegada date;
begin
  select * into so from solicitudes where id = p_id and not borrado for update;
  if not found then raise exception 'No existe'; end if;
  v_tipo := coalesce(nullif(p->>'tipo',''), so.tipo);
  if not (amex_req_priv.tiene(s,'comprar') or (amex_req_priv.tiene(s,'comprar_local') and coalesce(so.tipo,'local') = 'local' and v_tipo = 'local')) then
    raise exception 'Sin permiso para comprar este pedido'; end if;
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
  update solicitudes set tipo = v_tipo, proveedor = coalesce(p->>'proveedor', proveedor),
    estatus = coalesce(nullif(p->>'estatus',''), estatus), fecha_tentativa = v_llegada, comprador_nombre = s->>'nombre', updated_at = now()
  where id = p_id;
  perform amex_req_priv.recalcular(p_id);
  update solicitudes set estatus = 'por_aprobar' where id = p_id and aprobado_por is null
    and total_usd > (select value::numeric from config where key='umbral_aprobacion_usd');
  perform amex_req_priv.log(p_id, s->>'nombre', 'actualizó compra', p->>'estatus');
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.admin_guardar_solicitud(p_token uuid, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); v_id int := (p->>'id')::int;
begin
  if not amex_req_priv.tiene(s,'admin') then raise exception 'Solo admin'; end if;
  if coalesce(trim(p->>'osen'),'') = '' then raise exception 'La OSEN es obligatoria'; end if;
  update solicitudes set empresa = p->>'empresa', osen = upper(trim(p->>'osen')), prioridad = p->>'prioridad',
    fecha_tentativa = case when p ? 'fecha_tentativa' then nullif(p->>'fecha_tentativa','')::date else fecha_tentativa end,
    fecha_requerida = nullif(p->>'fecha_requerida','')::date, tipo = nullif(p->>'tipo',''), proveedor = p->>'proveedor',
    estatus = p->>'estatus', notas = p->>'notas', tc = coalesce(nullif(p->>'tc','')::numeric, tc), updated_at = now()
  where id = v_id;
  if p ? 'partidas' then
    update partidas set borrado = true where solicitud_id = v_id;
    perform amex_req_priv.insertar_partidas(v_id, p->'partidas');
  end if;
  perform amex_req_priv.recalcular(v_id);
  perform amex_req_priv.log(v_id, 'Admin', 'editó', null);
end $function$;
