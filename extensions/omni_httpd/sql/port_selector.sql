--- Force omni_httpd to select a port
begin;
with
    listener as (insert into omni_httpd.listeners (address, port) values ('127.0.0.1', 0) returning id),
    handler as (insert into omni_httpd.handlers (query) values ($$SELECT$$))
insert
into
    omni_httpd.listeners_handlers (listener_id, handler_id)
select
    listener.id,
    handler.id
from
    listener,
    handler;
delete
from
    omni_httpd.configuration_reloads;
end;

call omni_httpd.wait_for_configuration_reloads(1);

-- Ensure port was updated
select
    count(*)
from
    omni_httpd.listeners
where
    port = 0;

-- TODO: Test request on a given port. Needs non-shell http client