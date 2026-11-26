create table amex_req_priv.registros (
  id bigint generated always as identity primary key,
  nombre text not null,
  correo text not null unique,
  puesto text not null,
  codigo_hash text,
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobado','rechazado')),
  creado timestamptz not null default now(),
  resuelto timestamptz,
  revisado_por text,
  usuario_id integer references amex_requisiciones.usuarios(id) on delete set null
);

alter table amex_req_priv.registros enable row level security;
revoke all on amex_req_priv.registros from public, anon, authenticated;

create function amex_requisiciones.solicitar_acceso(p_nombre text,p_correo text,p_puesto text,p_codigo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  nombre_limpio text := btrim(coalesce(p_nombre,''));
  correo_limpio text := lower(btrim(coalesce(p_correo,'')));
  puesto_limpio text := btrim(coalesce(p_puesto,''));
begin
  if char_length(nombre_limpio) not between 2 and 100 or lower(nombre_limpio)='admin'
      or char_length(puesto_limpio) not between 2 and 100
      or char_length(correo_limpio) > 254 or correo_limpio !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Revisa tu nombre, correo y puesto';
  end if;
  if char_length(coalesce(p_codigo,'')) < 8 or octet_length(coalesce(p_codigo,'')) > 72 then
    raise exception 'La clave debe tener al menos 8 caracteres y como máximo 72 bytes';
  end if;
  if exists(select 1 from amex_req_priv.registros where correo=correo_limpio and estado<>'rechazado') then return; end if;

  insert into amex_req_priv.registros(nombre,correo,puesto,codigo_hash)
  values(nombre_limpio,correo_limpio,puesto_limpio,extensions.crypt(p_codigo,extensions.gen_salt('bf')))
  on conflict(correo) do update set nombre=excluded.nombre, puesto=excluded.puesto,
    codigo_hash=excluded.codigo_hash, estado='pendiente', creado=now(), resuelto=null, revisado_por=null
  where registros.estado='rechazado';
end;
$$;

create function amex_requisiciones.admin_registros(p_token uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare ses jsonb := amex_req_priv.sesion(p_token);
begin
  if not amex_req_priv.tiene(ses,'admin') then raise exception 'Solo Admin'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.id)
    from (select id,nombre,correo,puesto,creado from amex_req_priv.registros
      where estado='pendiente' order by id limit 100) r
  ),'[]'::jsonb);
end;
$$;

create function amex_requisiciones.admin_resolver_registro(
  p_token uuid,p_id bigint,p_aprobar boolean,p_permisos text[]
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  ses jsonb := amex_req_priv.sesion(p_token);
  registro amex_req_priv.registros%rowtype;
  nuevo_id integer;
begin
  if not amex_req_priv.tiene(ses,'admin') then raise exception 'Solo Admin'; end if;
  if p_aprobar is null then raise exception 'Indica una decisión'; end if;
  select * into registro from amex_req_priv.registros
    where id=p_id and estado='pendiente' for update;
  if not found then raise exception 'Este registro ya fue atendido'; end if;

  if p_aprobar then
    if cardinality(p_permisos) is null or cardinality(p_permisos)=0 or array_position(p_permisos,null) is not null
       or not (p_permisos <@ array['solicitar','comprar','comprar_local','recibir','aprobar','consulta']::text[]) then
      raise exception 'Selecciona permisos válidos';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('amex-registro:'||lower(registro.nombre),0));
    if exists(select 1 from amex_requisiciones.usuarios where lower(btrim(nombre))=lower(registro.nombre)) then
      raise exception 'Ya existe un usuario con este nombre. Revisa la sección Usuarios y roles.';
    end if;
    insert into amex_requisiciones.usuarios(nombre,puesto,codigo_hash,permisos,activo)
    values(registro.nombre,registro.puesto,registro.codigo_hash,p_permisos,true)
    returning id into nuevo_id;
  end if;

  update amex_req_priv.registros set estado=case when p_aprobar then 'aprobado' else 'rechazado' end,
    resuelto=now(), revisado_por=ses->>'nombre', usuario_id=nuevo_id, codigo_hash=null
  where id=p_id;
end;
$$;

revoke all on function amex_requisiciones.solicitar_acceso(text,text,text,text),
  amex_requisiciones.admin_registros(uuid), amex_requisiciones.admin_resolver_registro(uuid,bigint,boolean,text[])
  from public, authenticated;
grant execute on function amex_requisiciones.solicitar_acceso(text,text,text,text),
  amex_requisiciones.admin_registros(uuid), amex_requisiciones.admin_resolver_registro(uuid,bigint,boolean,text[])
  to anon;
notify pgrst, 'reload schema';
