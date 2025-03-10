-- Создаем временную таблицу
create temp table if not exists temp_script_vars (
    id serial primary key,
    table_name text not null
);

-- Очищаем предыдущие значения
truncate table temp_script_vars;

-- Вставляем имя целевой таблицы (поддерживает database.schema.table, schema.table, table)
insert into temp_script_vars (table_name)
values (:'table_name');

-- Основной анонимный блок
do $$
declare
    original_table_name text;
    target_table text;
    schema_name text;
    table_oid oid;
    column_info record;
    error_msg text;
    search_path_arr text[];
    parts text[];
    db_part text;
    schema_part text;
    table_part text;
    full_table_name text;
begin
    -- Получаем оригинальное имя таблицы
    select table_name into original_table_name 
    from temp_script_vars 
    limit 1;

    if original_table_name is null then
        raise exception 'Имя таблицы не указано';
    end if;

    -- Разбиваем имя таблицы на компоненты
    parts := parse_ident(original_table_name);

    -- Проверяем количество компонентов
    if array_length(parts, 1) > 3 or array_length(parts, 1) < 1 then
        raise exception 'Некорректный формат имени таблицы. Допустимые форматы: database.schema.table, schema.table, table';
    end if;

    -- Обрабатываем компоненты
    case array_length(parts, 1)
        when 3 then
            db_part := parts[1];
            schema_part := parts[2];
            table_part := parts[3];
            if db_part != current_database() then
                raise exception 'Указанная база данных "%" не совпадает с текущей "%"', db_part, current_database();
            end if;
            full_table_name := format('%I.%I', schema_part, table_part);
        when 2 then
            schema_part := parts[1];
            table_part := parts[2];
            full_table_name := format('%I.%I', schema_part, table_part);
        when 1 then
            schema_part := null;
            table_part := parts[1];
            full_table_name := table_part;
    end case;

    -- Проверяем существование схемы, если указана
    if schema_part is not null then
        if not exists (select 1 from pg_namespace where nspname = schema_part) then
            raise exception 'Схема "%" не существует', schema_part;
        end if;
    end if;

    -- Получаем OID таблицы
    table_oid := to_regclass(full_table_name);

    if table_oid is null then
        -- Формируем сообщение об ошибке
        show search_path into search_path_arr;
        if schema_part is not null then
            raise exception 'Таблица "%" не найдена в схеме "%"', table_part, schema_part;
        else
            raise exception 'Таблица "%" не найдена в search_path: %', table_part, search_path_arr;
        end if;
    end if;

    -- Получаем схему и имя таблицы из pg_class
    select nspname, relname 
    into schema_name, target_table
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where c.oid = table_oid;

    -- Проверяем соответствие схемы (если была указана)
    if schema_part is not null and schema_name != schema_part then
        raise exception 'Таблица "%" найдена в схеме "%", но ожидалась схема "%"', target_table, schema_name, schema_part;
    end if;

    -- Вывод заголовка
    raise notice e'Таблица: % (схема: "%")', target_table, schema_name;
    raise notice '%', format('%-3s %-20s %s', 'No.', 'Имя столбца', 'Атрибуты');
    raise notice '-------------------------------------------------------------';

    -- Цикл по столбцам
    for column_info in (
        select 
            a.attnum as ordinal,
            a.attname as column_name,
            format_type(a.atttypid, a.atttypmod) || 
            case when a.attnotnull then ' not null' else '' end as data_type,
            col_description(c.oid, a.attnum) as comment,
            con.constraints
        from
            pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            join pg_attribute a on a.attrelid = c.oid
            left join (
                select 
                    a.attname as column_name,
                    string_agg(
                        con.conname || ' ' ||
                        case con.contype
                            when 'p' then 'primary key'
                            when 'u' then 'unique'
                            when 'f' then 'foreign key'
                            when 'c' then 'check'
                            else 'other'
                        end,
                        ', '
                    ) as constraints
                from 
                    pg_constraint con
                    join pg_class cl on con.conrelid = cl.oid
                    join pg_namespace ns on cl.relnamespace = ns.oid
                    join pg_attribute a on a.attrelid = cl.oid and a.attnum = any(con.conkey)
                where 
                    cl.oid = table_oid
                group by a.attname
            ) con on a.attname = con.column_name
        where
            c.oid = table_oid
            and a.attnum > 0
            and not a.attisdropped
        order by a.attnum
    ) loop
        -- Вывод основной информации
        raise notice '%', format('%-3s %-20s Type: %s', 
            column_info.ordinal::text, 
            column_info.column_name, 
            column_info.data_type);

        -- Вывод комментария
        if column_info.comment is not null then
            raise notice '%', format('%-3s %-20s Comment: %s', '', '', column_info.comment);
        end if;

        -- Вывод ограничений
        if column_info.constraints is not null then
            raise notice '%', format('%-3s %-20s Constraint: %s', '', '', column_info.constraints);
        end if;
    end loop;

exception
    when others then
        get stacked diagnostics error_msg = message_text;
        raise notice 'Ошибка: %', error_msg;
        raise notice 'Проверьте:';
        raise notice '- Корректность формата имени таблицы (database.schema.table, schema.table, table)';
        raise notice '- Существование таблицы в указанной схеме или search_path';
        raise notice '- Соответствие базы данных (если указана) текущей БД';
end;
$$ language plpgsql;
