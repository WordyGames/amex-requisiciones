update amex_requisiciones.usuarios as kirman
set permisos = ricardo.permisos
from amex_requisiciones.usuarios as ricardo
where kirman.nombre='Kirman' and ricardo.nombre='Ricardo'
  and kirman.activo and ricardo.activo
  and kirman.permisos is distinct from ricardo.permisos;

create function amex_requisiciones.sesion_actual(p_token uuid)
returns jsonb language sql security definer set search_path = ''
as $$
  select amex_req_priv.sesion(p_token);
$$;

revoke all on function amex_requisiciones.sesion_actual(uuid) from public, authenticated;
grant execute on function amex_requisiciones.sesion_actual(uuid) to anon;
notify pgrst, 'reload schema';
