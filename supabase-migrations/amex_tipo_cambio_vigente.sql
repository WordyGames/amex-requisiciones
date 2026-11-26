create function amex_req_priv.tipo_cambio_vigente()
returns amex_requisiciones.tipo_cambio
language sql stable security definer set search_path = ''
as $$
  select *
  from amex_requisiciones.tipo_cambio
  where fecha <= (now() at time zone 'America/Mexico_City')::date
  order by fecha desc
  limit 1;
$$;

revoke all on function amex_req_priv.tipo_cambio_vigente() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION amex_requisiciones.admin_config(p_token uuid, p_umbral numeric, p_tc numeric, p_maestra text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones', 'extensions'
AS $function$
declare s jsonb := amex_req_priv.sesion(p_token);
begin
  if not amex_req_priv.tiene(s,'admin') then raise exception 'Solo admin'; end if;
  if p_umbral is not null then update config set value = p_umbral::text where key = 'umbral_aprobacion_usd'; end if;
  if p_tc is not null then
    insert into tipo_cambio(fecha,valor,fuente) values ((now() at time zone 'America/Mexico_City')::date, p_tc, 'manual')
    on conflict (fecha) do update set valor = excluded.valor, fuente = 'manual';
  end if;
  if coalesce(p_maestra,'') <> '' then update config set value = crypt(p_maestra, gen_salt('bf')) where key = 'clave_maestra_hash'; end if;
end $function$;

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
  if nullif(p->>'fecha_tentativa','') is null then raise exception 'Indica la fecha tentativa de llegada'; end if;
  if jsonb_array_length(coalesce(p->'partidas','[]')) = 0 then raise exception 'Agrega al menos una partida'; end if;
  insert into solicitudes(empresa, osen, prioridad, fecha_requerida, fecha_tentativa, solicita_id, solicita_nombre, notas, tc)
  values (coalesce(nullif(p->>'empresa',''),'Liumaq'), upper(trim(p->>'osen')), coalesce(nullif(p->>'prioridad',''),'normal'),
          nullif(p->>'fecha_requerida','')::date, nullif(p->>'fecha_tentativa','')::date, (s->>'id')::int, s->>'nombre', p->>'notas',
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

CREATE OR REPLACE FUNCTION amex_req_priv.recalcular(p_id integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
declare v_tc numeric; usd numeric; mxn numeric;
begin
  select tc into v_tc from solicitudes where id = p_id;
  if v_tc is null or v_tc = 0 then v_tc := (select valor from amex_req_priv.tipo_cambio_vigente()); end if;
  select coalesce(sum(case when moneda='USD' then cantidad*precio else cantidad*precio/v_tc end),0),
         coalesce(sum(case when moneda='MXN' then cantidad*precio else cantidad*precio*v_tc end),0)
    into usd, mxn from partidas where solicitud_id = p_id and not borrado;
  update solicitudes set total_usd = round(usd,2), total_mxn = round(mxn,2), tc = v_tc, updated_at = now() where id = p_id;
end $function$;

CREATE OR REPLACE FUNCTION amex_requisiciones.tc_actual()
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'amex_requisiciones'
AS $function$
  select coalesce((select jsonb_build_object('fecha',fecha,'valor',valor,'fuente',fuente) from amex_req_priv.tipo_cambio_vigente()),
    jsonb_build_object('fecha',null,'valor',null,'fuente',null))
  || jsonb_build_object('umbral_usd', (select value::numeric from config where key='umbral_aprobacion_usd')) $function$;
