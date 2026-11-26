create function amex_requisiciones.editar_solicitud_propia(p_token uuid, p_id integer, p jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  ses jsonb := amex_req_priv.sesion(p_token);
  pedido amex_requisiciones.solicitudes%rowtype;
  fecha date := nullif(p->>'fecha_requerida','')::date;
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
  if coalesce(p->>'prioridad','') not in ('normal','urgente') then raise exception 'Prioridad inválida'; end if;

  if p ? 'partidas' then
    if pedido.estatus not in ('por_aprobar','por_comprar') then
      raise exception 'Las partidas de una compra registrada debe corregirlas Admin'; end if;
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
    fecha_requerida=coalesce(fecha,pedido.fecha_requerida), prioridad=p->>'prioridad',
    notas=p->>'notas', updated_at=clock_timestamp()
  where id=p_id;
  perform amex_req_priv.log(p_id,ses->>'nombre','editó su solicitud',null);
end;
$$;

revoke all on function amex_requisiciones.editar_solicitud_propia(uuid,integer,jsonb) from public, authenticated;
grant execute on function amex_requisiciones.editar_solicitud_propia(uuid,integer,jsonb) to anon;
notify pgrst, 'reload schema';
