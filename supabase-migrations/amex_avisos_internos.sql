alter table amex_requisiciones.solicitudes add column etapa_desde timestamptz;

create function amex_req_priv.registrar_inicio_etapa()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.etapa_desde := now();
  elsif old.estatus is distinct from new.estatus then
    new.etapa_desde := now();
  end if;
  return new;
end;
$$;

revoke all on function amex_req_priv.registrar_inicio_etapa() from public, anon, authenticated;
create trigger requisicion_inicio_etapa before insert or update of estatus
on amex_requisiciones.solicitudes for each row execute function amex_req_priv.registrar_inicio_etapa();

create table amex_req_priv.avisos_eventos (
  id bigint generated always as identity primary key,
  solicitud_id integer not null references amex_requisiciones.solicitudes(id) on delete cascade,
  estatus text not null,
  creado timestamptz not null default now()
);

create table amex_req_priv.avisos_leidos (
  usuario integer not null,
  aviso bigint not null references amex_req_priv.avisos_eventos(id) on delete cascade,
  primary key (usuario, aviso)
);

alter table amex_req_priv.avisos_eventos enable row level security;
alter table amex_req_priv.avisos_leidos enable row level security;
revoke all on amex_req_priv.avisos_eventos, amex_req_priv.avisos_leidos from public, anon, authenticated;
create index avisos_eventos_solicitud on amex_req_priv.avisos_eventos (solicitud_id, id desc);

create function amex_req_priv.registrar_aviso()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if old.estatus is not distinct from new.estatus then return new; end if;
  end if;
  if not new.borrado then
    insert into amex_req_priv.avisos_eventos(solicitud_id, estatus)
    values (new.id, new.estatus);
  end if;
  return new;
end;
$$;

revoke all on function amex_req_priv.registrar_aviso() from public, anon, authenticated;
create trigger requisicion_aviso after insert or update of estatus
on amex_requisiciones.solicitudes for each row execute function amex_req_priv.registrar_aviso();

create function amex_requisiciones.avisos_internos(p_token uuid, p_leidos bigint[] default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
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
            amex_req_priv.tiene(ses, 'comprar')
            or (coalesce(s.tipo,'local') = 'local' and amex_req_priv.tiene(ses, 'comprar_local'))
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
$$;

revoke all on function amex_requisiciones.avisos_internos(uuid,bigint[]) from public, authenticated;
grant execute on function amex_requisiciones.avisos_internos(uuid,bigint[]) to anon;
notify pgrst, 'reload schema';
