create function amex_requisiciones.corregir_recepcion(
  p_token uuid,p_id integer,p_revision timestamptz,p_motivo text,p_partidas jsonb
)
returns text language plpgsql security definer set search_path = ''
as $$
declare
  ses jsonb := amex_req_priv.sesion(p_token);
  pedido amex_requisiciones.solicitudes%rowtype;
  partida amex_requisiciones.partidas%rowtype;
  cambio jsonb;
  cantidad_nueva numeric;
  motivo text := btrim(coalesce(p_motivo,''));
  detalle text[] := array[]::text[];
  estado_nuevo text;
begin
  if not amex_req_priv.tiene(ses,'recibir') then raise exception 'Sin permiso para corregir recepciones'; end if;
  if char_length(motivo) not between 3 and 500 then raise exception 'Escribe un motivo de entre 3 y 500 caracteres'; end if;
  if jsonb_typeof(p_partidas) is distinct from 'array' then raise exception 'Indica las partidas corregidas'; end if;
  if jsonb_array_length(p_partidas) not between 1 and 200 then raise exception 'Indica entre 1 y 200 partidas corregidas'; end if;
  if jsonb_array_length(p_partidas) <> (select count(distinct x->>'id') from jsonb_array_elements(p_partidas) x) then
    raise exception 'Las partidas corregidas deben ser distintas';
  end if;

  select * into pedido from amex_requisiciones.solicitudes where id=p_id and not borrado for update;
  if not found or pedido.estatus not in ('parcial','recibido') then
    raise exception 'Solo puedes corregir un pedido con recepción registrada';
  end if;
  if p_revision is null or p_revision is distinct from pedido.updated_at then
    raise exception 'El pedido cambió. Cierra y vuelve a abrir el detalle antes de corregirlo';
  end if;

  for cambio in select value from jsonb_array_elements(p_partidas) loop
    cantidad_nueva := nullif(cambio->>'cantidad','')::numeric;
    select * into partida from amex_requisiciones.partidas
      where id=(cambio->>'id')::int and solicitud_id=p_id and not borrado for update;
    if not found or cantidad_nueva is null or cantidad_nueva < 0 or cantidad_nueva > partida.cantidad then
      raise exception 'La cantidad corregida debe estar entre cero y lo pedido';
    end if;
    if cantidad_nueva is distinct from partida.cantidad_recibida then
      update amex_requisiciones.partidas set cantidad_recibida=cantidad_nueva where id=partida.id;
      detalle := array_append(detalle, format('#%s %s: %s → %s',
        partida.id,left(partida.descripcion,120),partida.cantidad_recibida,cantidad_nueva));
    end if;
  end loop;
  if cardinality(detalle)=0 then raise exception 'No cambió ninguna cantidad'; end if;

  if not exists(select 1 from amex_requisiciones.partidas where solicitud_id=p_id and not borrado and cantidad_recibida>0) then
    select detalle_evento.detalle into estado_nuevo from amex_requisiciones.solicitud_eventos detalle_evento
    where solicitud_id=p_id and accion='actualizó compra' and detalle_evento.detalle in ('comprado','en_transito')
    order by id desc limit 1;
    estado_nuevo := coalesce(estado_nuevo,'comprado');
  elsif exists(select 1 from amex_requisiciones.partidas where solicitud_id=p_id and not borrado and cantidad_recibida<cantidad) then
    estado_nuevo := 'parcial';
  else
    estado_nuevo := 'recibido';
  end if;
  update amex_requisiciones.solicitudes set estatus=estado_nuevo,updated_at=clock_timestamp() where id=p_id;
  perform amex_req_priv.log(p_id,ses->>'nombre','corrigió recepción',
    motivo||' · '||array_to_string(detalle,'; ')||' · Estatus: '||pedido.estatus||' → '||estado_nuevo);
  return estado_nuevo;
end;
$$;

revoke all on function amex_requisiciones.corregir_recepcion(uuid,integer,timestamptz,text,jsonb) from public, authenticated;
grant execute on function amex_requisiciones.corregir_recepcion(uuid,integer,timestamptz,text,jsonb) to anon;

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
      (coalesce(so.tipo,'local')<>'internacional' and (
        not solo_mias or (amex_req_priv.tiene(s,'ver_compras_locales') and so.estatus in ('por_comprar','comprado','en_transito'))
      )) or
      (so.tipo='internacional' and (
        amex_req_priv.tiene(s,'comprar_internacional') or
        (amex_req_priv.tiene(s,'seguimiento_internacional') and so.compra_iniciada_at is not null) or
        (amex_req_priv.tiene(s,'aprobar') and so.estatus='por_aprobar') or
        (amex_req_priv.tiene(s,'recibir') and so.estatus in ('comprado','en_transito','parcial','recibido'))
      ))
    )), '[]');
end $function$;

notify pgrst, 'reload schema';
