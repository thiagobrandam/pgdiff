module PgDiff
  class Queries
    include PgDiff::Utils

    attr_reader :label

    def initialize(connection, label = "unknown")
      @connection = connection
      @label = label
    end

    def roles
      query(%Q{
        SELECT rolname,
        rolname AS identity,
        oid AS objid,
        rolsuper,
        rolinherit,
        rolcreaterole,
        rolcreatedb,
        rolcanlogin,
        rolreplication,
        rolconnlimit,
        rolvaliduntil,
        rolbypassrls,
        rolconfig,
        '#{label}' AS origin
        FROM pg_roles where rolname !~ '^pg';
      })
    end

    def schemas
      query(%Q{
        SELECT nspname, nspowner::regrole::name as owner, oid as objid,
          (pg_identify_object('pg_namespace'::regclass, oid, 0)).identity,
          '#{label}' AS origin
          FROM pg_namespace
          WHERE nspname NOT IN ('pg_catalog','information_schema')
          AND nspname NOT LIKE 'pg_toast%'
          AND nspname NOT LIKE 'pg_temp%'
          AND nspname <> 'pgdiff';
      })
    end

    def extensions
      query(%Q{
        select
        nspname as schema,
        extname as name,
        extversion as version,
        e.oid as objid,
        (pg_identify_object('pg_extension'::regclass, e.oid, 0)).identity,
        '#{label}' AS origin
      from
          pg_extension e
          INNER JOIN pg_namespace
              ON pg_namespace.oid=e.extnamespace
      order by schema, name;
      })
    end

    def tables(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        SELECT schemaname, tablename, tableowner,
        (pg_identify_object('pg_class'::regclass, c.oid, 0)).identity,
        c.oid as objid,
        '#{label}' AS origin
        FROM pg_tables t
        INNER JOIN pg_namespace n ON t.schemaname = n.nspname
                INNER JOIN pg_class c ON t.tablename = c.relname AND c.relnamespace = n."oid"
                WHERE t.schemaname IN ('#{schemas.join("','")}')
                AND c.oid NOT IN (
                    SELECT d.objid
                    FROM pg_depend d
                    WHERE d.deptype = 'e'
                );
      })
    end

    def table_options(table_name)
      schema, table = schema_and_table(table_name)

      query(%Q{
        SELECT 'f' AS relhasoids, '#{label}' AS origin
        FROM pg_class c
        INNER JOIN pg_namespace n ON n."oid" = c.relnamespace AND n.nspname = '#{schema}'
        WHERE c.relname = '#{table}';
      })
    end

    def table_columns
      query(%Q{SELECT
      a.attname,
      a.attnotnull,
      tn.nspname,
      (pg_identify_object('pg_type'::regclass, t.oid, 0)).identity AS typname,
      t.oid as typeid,
      t.typcategory,
      ad.adbin,
      pg_get_expr(ad.adbin ,ad.adrelid ) as adsrc,
       a.attidentity,
      CASE
          WHEN t.typname = 'numeric' AND a.atttypmod > 0 THEN (a.atttypmod-4) >> 16
          WHEN (t.typname = 'bpchar' or t.typname = 'varchar') AND a.atttypmod > 0 THEN a.atttypmod-4
          ELSE null
      END AS precision,
      CASE
          WHEN t.typname = 'numeric' AND a.atttypmod > 0 THEN (a.atttypmod-4) & 65535
          ELSE null
      END AS scale,
      '#{label}' AS origin,
      n.nspname AS tnspname,
      c.relname,
      attrelid,
      a.attnum,
      attrelid || '.' || a.attnum AS objid
    FROM pg_attribute a
    INNER JOIN pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_attrdef ad on ad.adrelid = a.attrelid AND a.attnum = ad.adnum
    LEFT JOIN pg_catalog.pg_namespace tn ON tn.oid = t.typnamespace
    INNER JOIN pg_class c ON attrelid = c."oid"
    INNER JOIN pg_namespace n ON c.relnamespace = n."oid"
    INNER JOIN pg_tables tab ON tab.tablename = c.relname AND tab.schemaname = n.nspname
    WHERE attnum > 0 AND attisdropped = false
    ORDER BY n.nspname, c.relname, attrelid, a.attnum ASC;
      });
    end

    def table_constraints(table_name)
      schema, table = schema_and_table(table_name)

      query(%Q{
        SELECT conname, contype, conrelid, confrelid, array_to_json(coalesce(conkey, '{}'::int2[])) as pk_columns, array_to_json(coalesce(confkey, '{}'::int2[])) as fk_columns, conbin, pg_get_constraintdef(c.oid) as definition,
        (pg_identify_object('pg_constraint'::regclass, c.oid, 0)).identity,
        c.oid as objid,
        '#{label}' AS origin
        FROM pg_constraint c
        INNER JOIN pg_namespace n ON n.nspname = '#{schema}'
                INNER JOIN pg_class cl ON cl.relname ='#{table}' AND cl.relnamespace = n.oid
        WHERE c.conrelid = cl.oid;
      })
    end

    def table_indexes(table_name)
      schema, table = schema_and_table(table_name)

      query(%Q{
        with extension_oids as (
          select
              objid,
              classid::regclass::text as classid
          from
              pg_depend d
          WHERE
              d.refclassid = 'pg_extension'::regclass and
              d.classid = 'pg_index'::regclass
        ),
        extension_relations as (
          select
              objid
          from
              pg_depend d
          WHERE
              d.refclassid = 'pg_extension'::regclass and
              d.classid = 'pg_class'::regclass
        ), pre as (
            SELECT
           i.relname AS indexname,
           (pg_identify_object('pg_class'::regclass,i.oid, 0)).identity,
           i.oid as objid,
           '#{label}' AS origin,
           pg_get_indexdef(i.oid) AS indexdef,
               (
                   select
                       array_to_json(array_agg(attname order by ik.n))
                   from
                        unnest(x.indkey) with ordinality ik(i, n)
                        join pg_attribute aa
                            on
                                aa.attrelid = x.indrelid
                                and ik.i = aa.attnum
                ) AS columns_array
          FROM pg_index x
            JOIN pg_class c ON c.oid = x.indrelid
            JOIN pg_class i ON i.oid = x.indexrelid
            JOIN pg_am am ON i.relam = am.oid
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
             left join extension_oids e
              on i.oid = e.objid
            left join extension_relations er
              on c.oid = er.objid
        WHERE
            x.indislive
            and c.relkind in ('r', 'm', 'p') AND i.relkind in ('i', 'I')
            and nspname = '#{schema}' and c.relname = '#{table}'
        )
        select *
        from pre
        order by 1, 2, 3;
      })
    end

    def table_privileges
      query(%Q{
        SELECT distinct on (t.schemaname, t.tablename, c.oid)
        t.schemaname, t.tablename, '#{label}' AS origin,
        jsonb_agg(
          json_build_object(
            u.usename,
            jsonb_build_object(
              'SELECT', HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'SELECT'),
              'INSERT',  HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'INSERT'),
              'UPDATE', HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'UPDATE'),
              'DELETE', HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'DELETE'),
              'TRUNCATE', HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'TRUNCATE'),
              'REFERENCES',  HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'REFERENCES'),
              'TRIGGER', HAS_TABLE_PRIVILEGE(u.usename, t.schemaname || '.' || t.tablename, 'TRIGGER')
            )
          )
        ) AS privileges,
        c.oid || '.p' AS objid
        FROM pg_tables t, pg_user u, pg_namespace n, pg_class c
        WHERE n.nspname = t.schemaname
        AND c.relname = t.tablename
        GROUP BY t.schemaname, t.tablename, c.oid;
      })
    end

    def views(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        SELECT schemaname, viewname, viewowner, definition, 'VIRTUAL' AS viewtype,
        (pg_identify_object('pg_class'::regclass, c.oid, 0)).identity,
        c.oid as objid,
        '#{label}' AS origin
        FROM pg_views v
        INNER JOIN pg_namespace n ON v.schemaname = n.nspname
        INNER JOIN pg_class c ON v.viewname = c.relname AND c.relnamespace = n."oid"
                WHERE v.schemaname IN ('#{schemas.join("','")}')
                AND c.oid NOT IN (
                    SELECT d.objid
                    FROM pg_depend d
                    WHERE d.deptype = 'e'
        );
      })
    end

    def get_current_view_definition(oid)
      query(%{
        SELECT definition FROM pg_views v
        INNER JOIN pg_namespace n ON v.schemaname = n.nspname
        INNER JOIN pg_class c ON v.viewname = c.relname AND c.relnamespace = n."oid"
        WHERE c.oid = #{oid};
      })
    end

    def view_privileges
      query(%Q{
        SELECT
          distinct on (v.schemaname, v.viewname, c.oid)
          v.schemaname, v.viewname,'#{label}' AS origin,
          jsonb_agg(
            json_build_object(
              u.usename,
              jsonb_build_object(
                'SELECT', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'SELECT'),
                'INSERT',  HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'INSERT'),
                'UPDATE', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'UPDATE'),
                'DELETE', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'DELETE'),
                'TRUNCATE', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'TRUNCATE'),
                'REFERENCES',  HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'REFERENCES'),
                'TRIGGER', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.viewname, 'TRIGGER')
              )
            )
          ) AS privileges,
          c.oid || '.p' AS objid
        FROM pg_views v, pg_user u, pg_namespace n, pg_class c
        WHERE v.schemaname = n.nspname
        AND v.viewname = c.relname AND c.relnamespace = n."oid"
                AND c.oid NOT IN (
                    SELECT d.objid
                    FROM pg_depend d
                    WHERE d.deptype = 'e')
        GROUP BY v.schemaname, v.viewname, c.oid;
      })
    end

    def materialized_views(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        SELECT schemaname, matviewname AS viewname, matviewowner AS viewowner, definition,
        'MATERIALIZED' AS viewtype,
        (pg_identify_object('pg_class'::regclass, c.oid, 0)).identity,
        c.oid as objid,
        '#{label}' AS origin
        FROM pg_matviews v
        INNER JOIN pg_namespace n ON v.schemaname = n.nspname
        INNER JOIN pg_class c ON v.matviewname = c.relname AND c.relnamespace = n."oid"
        WHERE v.schemaname IN ('#{schemas.join("','")}');
      })
    end

    def materialized_view_privileges
      query(%Q{
        SELECT
          distinct on (v.schemaname, v.matviewname, c.oid)
          v.schemaname, v.matviewname as viewname,'#{label}' AS origin,
          jsonb_agg(
            json_build_object(
              u.usename,
              jsonb_build_object(
                'SELECT', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'SELECT'),
                'INSERT',  HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'INSERT'),
                'UPDATE', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'UPDATE'),
                'DELETE', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'DELETE'),
                'TRUNCATE', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'TRUNCATE'),
                'REFERENCES',  HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'REFERENCES'),
                'TRIGGER', HAS_TABLE_PRIVILEGE(u.usename, v.schemaname || '.' || v.matviewname, 'TRIGGER')
              )
            )
          ) AS privileges,
          c.oid || '.p' AS objid
        FROM pg_matviews v, pg_user u, pg_namespace n, pg_class c
        WHERE v.schemaname = n.nspname
        AND v.matviewname = c.relname AND c.relnamespace = n."oid"
        GROUP BY v.schemaname, v.matviewname, c.oid;
      })
    end

    def view_dependencies
      query(%Q{
        SELECT
        r.oid AS objid,
        jsonb_agg(
          jsonb_build_object(
            'schemaname',  n.nspname,
            'tablename', c.relname,
            'columnname', a.attname,
            'rtype', (CASE r.ev_type WHEN '1' THEN 'SELECT' WHEN '2' THEN 'UPDATE' WHEN '3' THEN 'INSERT' ELSE 'DELETE' END),
            'viewname', (pg_identify_object('pg_class'::regclass, r.ev_class, 0)).identity,
            'fobjid', fd.refobjid
          )
        ) AS ops,
        (pg_identify_object('pg_rewrite'::regclass, r.oid, 0)).identity AS identity,
        '#{label}' AS origin
        FROM pg_rewrite AS r
        INNER JOIN pg_depend AS d ON r.oid=d.objid
        LEFT JOIN pg_depend AS fd ON r.oid = fd.objid AND fd.refclassid = 'pg_proc'::regclass
        INNER JOIN pg_attribute a ON a.attnum = d.refobjsubid AND a.attrelid = d.refobjid AND a.attisdropped = false
        INNER JOIN pg_class c ON c.oid = d.refobjid
        INNER JOIN pg_namespace n ON n.oid = c.relnamespace
        GROUP BY r.oid;
      })
    end

    def functions(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        SELECT p.proname, n.nspname, pg_get_functiondef(p.oid) as definition, p.prosrc, p.proowner::regrole::name as owner, oidvectortypes(proargtypes) as argtypes,
        (pg_identify_object('pg_proc'::regclass, p.oid, 0)).identity,
        p.oid as objid,
        '#{label}' AS origin,
        p."oid" IN (
          SELECT d.objid
          FROM pg_depend d
          WHERE d.deptype = 'e'
      ) AS extension_function
        FROM pg_proc p
        INNER JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.prokind in ('f','p');
      })
    end

    def aggregates(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        SELECT p.proname, n.nspname, p.proowner::regrole::name as owner, oidvectortypes(proargtypes) as argtypes,
        format('%s', array_to_string(
          ARRAY[
            format(E'\\tSFUNC = %s', a.aggtransfn::text)
            , format(E'\\tSTYPE = %s', format_type(a.aggtranstype, NULL))
            , format(E'\\tSSPACE = %s',a.aggtransspace)
            , CASE a.aggfinalfn WHEN '-'::regproc THEN NULL ELSE format(E'\\tFINALFUNC = %s',a.aggfinalfn::text) END
            , CASE WHEN a.aggfinalfn != '-'::regproc AND a.aggfinalextra = true THEN format(E'\\tFINALFUNC_EXTRA') ELSE NULL END
            , CASE WHEN a.aggfinalfn != '-'::regproc THEN format(E'\\tFINALFUNC_MODIFY = %s',
              CASE
                WHEN a.aggfinalmodify = 'r' THEN 'READ_ONLY'
                WHEN a.aggfinalmodify = 's' THEN 'SHAREABLE'
                WHEN a.aggfinalmodify = 'w' THEN 'READ_WRITE'
              END
            ) ELSE NULL END
            , CASE WHEN a.agginitval IS NULL THEN NULL ELSE format(E'\\tINITCOND = %s', quote_literal(a.agginitval)) END
            , format(E'\\tPARALLEL = %s',
              CASE
                WHEN p.proparallel = 'u' THEN 'UNSAFE'
                WHEN p.proparallel = 's' THEN 'SAFE'
                WHEN p.proparallel = 'r' THEN 'RESTRICTED'
              END
            )
            , CASE a.aggcombinefn WHEN '-'::regproc THEN NULL ELSE format(E'\\tCOMBINEFUNC = %s',a.aggcombinefn::text) END
            , CASE a.aggserialfn WHEN '-'::regproc THEN NULL ELSE format(E'\\tSERIALFUNC = %s',a.aggserialfn::text) END
            , CASE a.aggdeserialfn WHEN '-'::regproc THEN NULL ELSE format(E'\\tDESERIALFUNC = %s',a.aggdeserialfn::text) END
            , CASE a.aggmtransfn WHEN '-'::regproc THEN NULL ELSE format(E'\\tMSFUNC = %s',a.aggmtransfn::text) END
            , case a.aggmtranstype WHEN '-'::regtype THEN NULL ELSE format(E'\\tMSTYPE = %s', format_type(a.aggmtranstype, NULL)) END
            , case WHEN a.aggmfinalfn != '-'::regproc THEN format(E'\\tMSSPACE = %s',a.aggmtransspace) ELSE NULL END
            , CASE a.aggminvtransfn WHEN '-'::regproc THEN NULL ELSE format(E'\\tMINVFUNC = %s',a.aggminvtransfn::text) END
            , CASE a.aggmfinalfn WHEN '-'::regproc THEN NULL ELSE format(E'\\tMFINALFUNC = %s',a.aggmfinalfn::text) END
            , CASE WHEN a.aggmfinalfn != '-'::regproc and a.aggmfinalextra = true THEN format(E'\\tMFINALFUNC_EXTRA') ELSE NULL END
            , CASE WHEN a.aggmfinalfn != '-'::regproc THEN format(E'\\tMFINALFUNC_MODIFY  = %s',
              CASE
                WHEN a.aggmfinalmodify = 'r' THEN 'READ_ONLY'
                WHEN a.aggmfinalmodify = 's' THEN 'SHAREABLE'
                WHEN a.aggmfinalmodify = 'w' THEN 'READ_WRITE'
              END
            ) ELSE NULL END
            , CASE WHEN a.aggminitval IS NULL THEN NULL ELSE format(E'\\tMINITCOND = %s', a.aggminitval) END
            , CASE a.aggsortop WHEN 0 THEN NULL ELSE format(E'\\tSORTOP = %s', o.oprname) END
          ]
          , E',\\n'
          )
        ) as definition,
        (pg_identify_object('pg_proc'::regclass, p.oid, 0)).identity,
        '#{label}' AS origin,
        p.oid as objid
                FROM pg_proc p
        INNER JOIN pg_namespace n ON n.oid = p.pronamespace
        INNER JOIN pg_aggregate a on p.oid = a.aggfnoid
        LEFT JOIN pg_operator o ON o.oid = a.aggsortop
        WHERE n.nspname IN ('#{schemas.join("','")}')
        AND a.aggkind = 'n'
        AND p.prokind = 'a'
        AND p."oid" NOT IN (
                    SELECT d.objid
                    FROM pg_depend d
                    WHERE d.deptype = 'e'
                );
      })
    end

    def function_privileges
      query(%Q{
        SELECT
        distinct on (n.nspname, p.proname, p.oid)
        n.nspname as pronamespace, p.proname, '#{label}' AS origin,
        p.oid || '.p' AS objid,
        jsonb_agg(
          json_build_object(
            u.usename,
            json_build_object(
              'EXECUTE', HAS_FUNCTION_PRIVILEGE(u.usename, p.oid,'EXECUTE')
            )
          )
        ) AS privileges
        FROM pg_proc p, pg_user u, pg_namespace n
        WHERE n.oid = p.pronamespace
        GROUP BY n.nspname, p.proname, p.oid;
      })
    end

    def sequences(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        SELECT seq_nspname, seq_name, owner, ownedby_table, ownedby_column,
              p.start_value, p.minimum_value, p.maximum_value, p.increment,
              p.cycle_option, p.cache_size,
              (pg_identify_object('pg_class'::regclass, s.oid, 0)).identity,
              s.oid as objid,
              '#{label}' AS origin
                    FROM (
                        SELECT
                            c.oid, ns.nspname AS seq_nspname, c.relname AS seq_name, r.rolname as owner, (pg_identify_object('pg_class'::regclass, sc.oid, 0)).identity AS ownedby_table, a.attname AS ownedby_column
                        FROM pg_class c
                        INNER JOIN pg_namespace ns ON ns.oid = c.relnamespace
                        INNER JOIN pg_roles r ON r.oid = c.relowner
                        INNER JOIN pg_depend d ON d.objid = c.oid AND d.refobjsubid > 0 AND d.deptype ='a'
              INNER JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
              INNER JOIN pg_class sc ON sc."oid" = d.refobjid
                        WHERE c.relkind = 'S' AND ns.nspname IN ('#{schemas.join("','")}')
                        AND a.attidentity = ''
                    ) s, LATERAL pg_sequence_parameters(s.oid) p;
      })
    end

    def sequence_privileges
      query(%Q{
        SELECT distinct on (s.sequence_schema, s.sequence_name, c.oid)
        s.sequence_schema, s.sequence_name, '#{label}' AS origin,
        jsonb_agg(
          json_build_object(
            u.usename,
            json_build_object(
              'SELECT', HAS_SEQUENCE_PRIVILEGE(u.usename, s.sequence_schema || '.' || s.sequence_name, 'SELECT'),
              'USAGE',  HAS_SEQUENCE_PRIVILEGE(u.usename, s.sequence_schema || '.' || s.sequence_name, 'USAGE'),
              'UPDATE', HAS_SEQUENCE_PRIVILEGE(u.usename, s.sequence_schema || '.' || s.sequence_name, 'UPDATE')
            )
          )
        ) AS privileges,
        c.oid || '.p' AS objid
        FROM information_schema.sequences s, pg_user u, pg_namespace ns, pg_class c
        WHERE c.relname = s.sequence_name AND ns.nspname = s.sequence_schema
        GROUP BY s.sequence_schema, s.sequence_name, c.oid;
      })
    end

    def enums(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        WITH extension_oids AS (
          SELECT
              objid
          FROM
              pg_depend d
          WHERE
              d.refclassid = 'pg_extension'::regclass AND
              d.classid = 'pg_type'::regclass
        )
        SELECT
          n.nspname AS "schema",
          t.typname AS "name",
          ARRAY(
            SELECT e.enumlabel
              FROM pg_catalog.pg_enum e
              WHERE e.enumtypid = t.oid
              ORDER BY e.enumsortorder
          ) AS elements,
          (pg_identify_object('pg_type'::regclass, t.oid, 0)).identity,
          t.oid as objid,
          (t.oid in (select * from extension_oids)) as from_extension,
          '#{label}' AS origin
        FROM pg_catalog.pg_type t
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
            LEFT OUTER JOIN extension_oids e
              ON t.oid = e.objid
        WHERE
          t.typtype = 'e'
          AND e.objid IS NULL
        ORDER BY 1, 2;
      })
    end

    def domains(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        WITH extension_oids AS (
          SELECT
              objid
          FROM
              pg_depend d
          WHERE
              d.refclassid = 'pg_extension'::regclass AND
              d.classid = 'pg_type'::regclass
        )
        SELECT n.nspname as "schema",
              t.typname as "name",
              pg_catalog.format_type(t.typbasetype, t.typtypmod) as "data_type",
              (CASE t.typtype WHEN 'd' THEN 'domain' WHEN 'e' THEN 'enum' ELSE NULL END) AS "type",
              (SELECT c.collname FROM pg_catalog.pg_collation c, pg_catalog.pg_type bt
                WHERE c.oid = t.typcollation AND bt.oid = t.typbasetype AND t.typcollation <> bt.typcollation) as "collation",
              t.typnotnull as "not_null",
              t.typdefault as "default",
              (pg_identify_object('pg_type'::regclass, t.oid, 0)).identity,
              t.oid as objid,
              (t.oid in (select * from extension_oids)) as from_extension,
              '#{label}' AS origin
        FROM pg_catalog.pg_type t
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        WHERE t.typtype = 'd'
            AND (t.typrelid = 0 OR (SELECT c.relkind = 'c' FROM pg_catalog.pg_class c WHERE c.oid = t.typrelid))
            AND  NOT EXISTS(SELECT 1 FROM pg_catalog.pg_type el WHERE el.oid = t.typelem AND el.typarray = t.oid)
        ORDER BY 1, 2;
      })
    end

    def domain_constraints
      query(%Q{
        WITH extension_oids AS (
          SELECT
              objid
          FROM
              pg_depend d
          WHERE
              d.refclassid = 'pg_extension'::regclass AND
              d.classid = 'pg_type'::regclass
        )
        SELECT rr.conname as "constraint_name",
              pg_catalog.pg_get_constraintdef(rr.oid, true) AS "definition",
              (pg_identify_object('pg_constraint'::regclass, rr.oid, 0)).identity,
              rr.oid as objid,
              (n.nspname || '.' || t.typname) AS domain_name,
              '#{label}' AS origin
        FROM pg_catalog.pg_type t
          LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
          LEFT JOIN pg_catalog.pg_constraint rr on t.oid = rr.contypid
        WHERE t.typtype = 'd'
          AND rr.conname IS NOT NULL
          AND (t.typrelid = 0 OR (SELECT c.relkind = 'c' FROM pg_catalog.pg_class c WHERE c.oid = t.typrelid))
          AND  NOT EXISTS(SELECT 1 FROM pg_catalog.pg_type el WHERE el.oid = t.typelem AND el.typarray = t.oid)
        ORDER BY 1, 2;
      })
    end

    def types(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        with extension_oids as (
          select
              objid
          from
              pg_depend d
          WHERE
              d.refclassid = 'pg_extension'::regclass and
              d.classid = 'pg_type'::regclass
        )
        SELECT
          n.nspname AS schema,
          pg_catalog.format_type (t.oid, NULL) AS name,
          t.typname AS internal_name,
          t.typtype AS type,
          t.typcategory AS category,
          CASE
            WHEN t.typrelid != 0
              THEN CAST ( 'tuple' AS pg_catalog.text )
            WHEN t.typlen < 0
              THEN CAST ( 'var' AS pg_catalog.text )
            ELSE CAST ( t.typlen AS pg_catalog.text )
          END AS size,
          pg_catalog.array_to_string (
            ARRAY(
              SELECT e.enumlabel
                FROM pg_catalog.pg_enum e
                WHERE e.enumtypid = t.oid
                ORDER BY e.oid ), E'\n'
            ) AS columns,
          pg_catalog.obj_description (t.oid, 'pg_type') AS description,
          (array_to_json(array(
            select
              jsonb_build_object('attribute', attname, 'type', an.nspname || '.' || a.typname, 'objid', a.oid, 'identity', (pg_identify_object('pg_type'::regclass, a.oid, 0)).identity, 'origin', '#{label}')
            from pg_class
            join pg_attribute on (attrelid = pg_class.oid)
            join pg_type a on (atttypid = a.oid)
            JOIN pg_catalog.pg_namespace an ON an.oid = a.typnamespace
            where (pg_class.reltype = t.oid)
          ))) as columns,
          (pg_identify_object('pg_type'::regclass, t.oid, 0)).identity,
          t.oid as objid,
          (t.oid in (select * from extension_oids)) as from_extension,
          '#{label}' AS origin
        FROM
          pg_catalog.pg_type t
          LEFT JOIN pg_catalog.pg_namespace n
            ON n.oid = t.typnamespace
        WHERE (
          t.typrelid = 0
          OR (
            SELECT c.relkind = 'c'
              FROM pg_catalog.pg_class c
              WHERE c.oid = t.typrelid
          )
        )
        and t.typtype NOT IN ('e', 'd')
        ORDER BY 1, 2;
      })
    end

    def triggers(schemas = self.schemas.map{|row| row["nspname"] })
      query(%Q{
        with extension_oids as (
          select
              objid
          from
              pg_depend d
          WHERE
            d.refclassid = 'pg_extension'::regclass and
            d.classid = 'pg_trigger'::regclass
        )
        select
            tg.tgname "name",
            nspp.nspname "schema",
            cls.relname table_name,
            nsp.nspname table_schema,
            pg_get_triggerdef(tg.oid) definition,
            proc.proname proc_name,
            nspp.nspname proc_schema,
            oidvectortypes(proc.proargtypes) proc_argtypes,
            tg.tgenabled enabled,
            tg.oid in (select * from extension_oids) as extension_owned,
            (pg_identify_object('pg_trigger'::regclass, tg.oid, 0)).identity,
            tg.oid as objid,
            tgfoid,
            (tg.oid in (select * from extension_oids)) as from_extension,
            tg.tgattr,
            '#{label}' AS origin
        from pg_trigger tg
        join pg_class cls on cls.oid = tg.tgrelid
        join pg_namespace nsp on nsp.oid = cls.relnamespace
        join pg_proc proc on proc.oid = tg.tgfoid
        join pg_namespace nspp on nspp.oid = proc.pronamespace
        where not tg.tgisinternal
              AND nsp.nspname IN ('#{schemas.join("','")}')
        order by schema, table_name, name;
      })
    end

    # From https://wiki.postgresql.org/wiki/Pg_depend_display
    def dependency_pairs
      query(%Q{
        WITH recursive preference AS (
          SELECT 15 AS max_depth
            , 1 AS min_oid -- user objects only
            , '^(everything)'::text AS schema_exclusion
            , '^pg_(conversion|language|ts_(dict|template))'::text AS class_exclusion
        ),
        dependency_pair AS (
          SELECT distinct on (objid, refobjid)
              objid
            , objsubid
            , upper(obj.type) AS object_type
            , coalesce(obj.schema, substring(obj.identity, E'(\\w+?)\\.'), '') AS object_schema
            , obj.name AS object_name
            , obj.identity AS object_identity
            , refobjid
            , refobjsubid
            , upper(refobj.type) AS refobj_type
            , coalesce(CASE WHEN refobj.type='schema' THEN refobj.identity
                                                      ELSE refobj.schema END
                , substring(refobj.identity, E'(\\w+?)\\.'), '') AS refobj_schema
            , refobj.name AS refobj_name
            , refobj.identity AS refobj_identity
            , CASE deptype
                  WHEN 'n' THEN 'normal'
                  WHEN 'a' THEN 'automatic'
                  WHEN 'i' THEN 'internal'
                  WHEN 'e' THEN 'extension'
                  WHEN 'p' THEN 'pinned'
              END AS dependency_type
          FROM pg_depend dep
            , LATERAL pg_identify_object(classid, objid, 0) AS obj
            , LATERAL pg_identify_object(refclassid, refobjid, 0) AS refobj
            , preference
          WHERE deptype = ANY('{n,a,i,e,p}')
          AND objid >= preference.min_oid
          AND (refobjid >= preference.min_oid OR refobjid = 2200) -- need public schema as root node
          AND coalesce(obj.schema, substring(obj.identity, E'(\\w+?)\\.'), '') !~ preference.schema_exclusion
          AND coalesce(CASE WHEN refobj.type='schema' THEN refobj.identity
                                                      ELSE refobj.schema END
                , substring(refobj.identity, E'(\\w+?)\\.'), '') !~ preference.schema_exclusion
          GROUP BY objid, objsubid, obj.type, obj.schema, obj.name, obj.identity
            , refobjid, refobjsubid, refobj.type, refobj.schema, refobj.name, refobj.identity, deptype
        )
        , dependency_hierarchy AS (
          SELECT DISTINCT
              0 AS level,
              refobjid AS objid,
              refobjsubid AS objsubid,
              refobj_type AS object_type,
              refobj_identity AS object_identity,
              NULL::text AS dependency_type,
              ARRAY[refobjid] AS dependency_chain
          FROM dependency_pair root
          , preference
          WHERE NOT EXISTS
             (SELECT 'x' FROM dependency_pair branch WHERE branch.objid = root.refobjid)
          AND refobj_schema !~ preference.schema_exclusion
          UNION ALL
          SELECT
              level + 1 AS level,
              child.objid,
              child.objsubid,
              child.object_type,
              child.object_identity,
              child.dependency_type,
              parent.dependency_chain || child.objid
          FROM dependency_pair child
          JOIN dependency_hierarchy parent ON (parent.objid = child.refobjid)
          , preference
          WHERE level < preference.max_depth
          AND child.object_schema !~ preference.schema_exclusion
          AND child.refobj_schema !~ preference.schema_exclusion
          AND NOT (child.objid = ANY(parent.dependency_chain))
      )
      SELECT level, objid, objsubid, object_type, object_identity, dependency_type, to_json(dependency_chain::text[]) AS dependency_chain FROM dependency_hierarchy
      ORDER BY level, objid, objsubid;
      })
    end

    private

    def query(q)
      @connection.exec(q).entries
    end
  end
end
