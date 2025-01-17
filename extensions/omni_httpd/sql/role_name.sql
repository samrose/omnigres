create role test_user inherit in role current_user;
create role test_user1 inherit in role current_user;

set role test_user;

-- Should use current_user as a default role_name
begin;
with
    listener as (insert into omni_httpd.listeners (address, port) values ('127.0.0.1', 9003) returning id),
    handler as (insert into omni_httpd.handlers (query) values
                                                            ($$SELECT omni_httpd.http_response(body => current_user::text) FROM request$$) returning id)
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

-- Can't update it to an arbitrary name
begin;
update omni_httpd.handlers
set
    role_name = 'some_role'
where
    role_name = 'test_user';
delete
from
    omni_httpd.configuration_reloads;
end;
call omni_httpd.wait_for_configuration_reloads(1);

-- Can't update it to a name that is not a current user
begin;
update omni_httpd.handlers
set
    role_name = 'test_user1'
where
    role_name = 'test_user';
delete
from
    omni_httpd.configuration_reloads;
end;
call omni_httpd.wait_for_configuration_reloads(1);

-- Can update it to a name that is a current user
set role test_user1;
begin;
update omni_httpd.handlers
set
    role_name = 'test_user1'
where
    role_name = 'test_user';
delete
from
    omni_httpd.configuration_reloads;
end;
call omni_httpd.wait_for_configuration_reloads(1);

-- When changing the query, should always set current user
set role test_user;
update omni_httpd.handlers
set
    query = $$SELECT omni_httpd.http_response(body => current_user::text) FROM request$$
where
    role_name = 'test_user1'
returning role_name;
-- This will work
begin;
update omni_httpd.handlers
set
    query     = $$SELECT omni_httpd.http_response(body => current_user::text) FROM request$$,
    role_name = 'test_user'
where
    role_name = 'test_user1'
returning role_name;

delete
from
    omni_httpd.configuration_reloads;
end;
call omni_httpd.wait_for_configuration_reloads(1);


\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent http://localhost:9003/