create table users
(
    id     integer primary key generated always as identity,
    handle text,
    name   text
);

insert
into
    users (handle, name)
values
    ('johndoe', 'John');

begin;
with
    listener as (insert into omni_httpd.listeners (address, port) values ('127.0.0.1', 9000) returning id),
    handler as (insert into omni_httpd.handlers (query)
        select
            omni_httpd.cascading_query(name, query order by priority desc nulls last)
        from
            (values
                 ('hello',
                  $$SELECT omni_httpd.http_response(headers => array[omni_httpd.http_header('content-type', 'text/html')], body => 'Hello, <b>' || users.name || '</b>!')
       FROM request
       INNER JOIN users ON string_to_array(request.path,'/', '') = array[NULL, 'users', users.handle]
      $$, 1),
                 ('headers',
                  $$SELECT omni_httpd.http_response(body => request.headers::text) FROM request WHERE request.path = '/headers'$$,
                  1),
                 ('echo',
                  $$SELECT omni_httpd.http_response(body => request.body) FROM request WHERE request.path = '/echo'$$,
                  1),
                 -- This validates that `request CTE` can be casted to http_request
                 ('http_request',
                  $$SELECT omni_httpd.http_response(body => request.*::omni_httpd.http_request::text) FROM request WHERE request.path = '/http_request'$$,
                  1),
                 ('not_found',
                  $$SELECT omni_httpd.http_response(status => 404, body => json_build_object('method', request.method, 'path', request.path, 'query_string', request.query_string))
       FROM request$$, 0)) as routes(name, query, priority)
        returning id)
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

-- Now, the actual tests

-- FIXME: for the time being, since there's no "request" extension yet, we're shelling out to curl

\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent -w '\n%{response_code}\nContent-Type: %header{content-type}\n\n' http://localhost:9000/test?q=1

\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent -w '\n%{response_code}\nContent-Type: %header{content-type}\n\n' -d 'hello world' http://localhost:9000/echo

\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent -w '\n%{response_code}\nContent-Type: %header{content-type}\n\n' http://localhost:9000/users/johndoe

\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent -A test-agent http://localhost:9000/headers

-- Try changing configuration

begin;

update omni_httpd.listeners
set
    port = 9001
where
    port = 9000;
with
    listener as (insert into omni_httpd.listeners (address, port) values ('127.0.0.1', 9002) returning id),
    handler as (select
                    ls.handler_id as id
                from
                    omni_httpd.listeners
                    inner join omni_httpd.listeners_handlers ls on ls.listener_id = listeners.id
                where
                    port = 9001)
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


\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent -w '\n%{response_code}\nContent-Type: %header{content-type}\n\n' http://localhost:9001/test?q=1

\! curl --retry-connrefused --retry 10  --retry-max-time 10 --silent -w '\n%{response_code}\nContent-Type: %header{content-type}\n\n' http://localhost:9002/test?q=1

\! curl --silent http://localhost:9000/test?q=1 || echo "failed as it should"