CREATE OR REPLACE FUNCTION amex_requisiciones.actualizar_compra(p_token uuid, p_id integer, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); so record; x jsonb; v_tipo text;
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
  for x in select * from jsonb_array_elements(coalesce(p->'partidas','[]')) loop
    update partidas set precio = coalesce(nullif(x->>'precio','')::numeric, precio),
                        moneda = coalesce(nullif(upper(x->>'moneda'),''), moneda)
    where id = (x->>'id')::int and solicitud_id = p_id;
  end loop;
  update solicitudes set tipo = v_tipo, proveedor = coalesce(p->>'proveedor', proveedor),
    estatus = coalesce(nullif(p->>'estatus',''), estatus), comprador_nombre = s->>'nombre', updated_at = now()
  where id = p_id;
  perform amex_req_priv.recalcular(p_id);
  update solicitudes set estatus = 'por_aprobar' where id = p_id and aprobado_por is null
    and total_usd > (select value::numeric from config where key='umbral_aprobacion_usd');
  perform amex_req_priv.log(p_id, s->>'nombre', 'actualizó compra', p->>'estatus');
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.recibir_solicitud(p_token uuid, p_id integer, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token); x jsonb; faltan int; recibido numeric; saldo numeric;
begin
  if not amex_req_priv.tiene(s,'recibir') then raise exception 'Sin permiso para recibir'; end if;
  perform 1 from solicitudes where id=p_id and not borrado and estatus in ('comprado','en_transito','parcial') for update;
  if not found then raise exception 'El pedido no está pendiente de recepción'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(p,'[]')) a where (a->>'cantidad')::numeric > 0) then
    raise exception 'Indica cantidades por recibir'; end if;
  for x in select * from jsonb_array_elements(coalesce(p,'[]')) loop
    recibido := coalesce(nullif(x->>'cantidad','')::numeric,0);
    select cantidad-cantidad_recibida into saldo from partidas
    where id=(x->>'id')::int and solicitud_id=p_id and not borrado for update;
    if not found or recibido < 0 or recibido > saldo then
      raise exception 'Cantidad inválida para la partida'; end if;
    update partidas set cantidad_recibida = cantidad_recibida + recibido
    where id = (x->>'id')::int and solicitud_id = p_id;
  end loop;
  select count(*) into faltan from partidas where solicitud_id = p_id and not borrado and cantidad_recibida < cantidad;
  update solicitudes set estatus = case when faltan = 0 then 'recibido' else 'parcial' end, updated_at = now() where id = p_id;
  perform amex_req_priv.log(p_id, s->>'nombre', 'recibió', case when faltan = 0 then 'completo' else 'parcial' end);
end $function$;
