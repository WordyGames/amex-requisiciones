update amex_requisiciones.usuarios
set permisos=array_append(permisos,'ver_compras_locales')
where nombre='Kirman' and activo and not ('ver_compras_locales'=any(permisos));

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
        (amex_req_priv.tiene(s,'recibir') and so.estatus in ('comprado','en_transito','parcial'))
      ))
    )), '[]');
end $function$;
