/*
    SQL Server 2016+.
    Install in an administration database. Execute there to maintain user databases
    on the same instance. Run as a principal with database visibility, VIEW DATABASE
    STATE, and ALTER permission on the selected tables (typically a DBA login).
*/
CREATE OR ALTER PROCEDURE dbo.usp_DefragIndexes
    @Targets nvarchar(max) = NULL,
    @Criterion varchar(16),
    @MinPageFullness decimal(5,2) = 75.00,
    @MinLinkFragmentation decimal(5,2) = 10.00,
    @RebuildAtFragmentation decimal(5,2) = 30.00,
    @MinPageCount int = 1000,
    @MaxOperations int = NULL,
    @MaxDop int = 0,
    @OnlineRebuild bit = 0,
    @StatsGovernanceDatabase sysname = NULL,
    @StatsGovernanceMode varchar(10) = 'NONE',
    @Execute bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Criterion IS NULL OR @Criterion NOT IN ('PAGE_FULLNESS', 'PAGE_LINK')
        THROW 50001, 'Criterion must be PAGE_FULLNESS or PAGE_LINK.', 1;
    IF @MinPageFullness <= 0 OR @MinPageFullness > 100 OR @MinPageFullness IS NULL
        THROW 50002, 'MinPageFullness must be greater than 0 and at most 100.', 1;
    IF @MinLinkFragmentation < 0 OR @MinLinkFragmentation > 100 OR @MinLinkFragmentation IS NULL
        THROW 50003, 'MinLinkFragmentation must be between 0 and 100.', 1;
    IF @RebuildAtFragmentation < @MinLinkFragmentation OR @RebuildAtFragmentation > 100 OR @RebuildAtFragmentation IS NULL
        THROW 50004, 'RebuildAtFragmentation must be between MinLinkFragmentation and 100.', 1;
    IF @MinPageCount < 1 OR @MinPageCount IS NULL
        THROW 50005, 'MinPageCount must be positive.', 1;
    IF @MaxOperations IS NOT NULL AND @MaxOperations < 1
        THROW 50006, 'MaxOperations must be positive or NULL.', 1;
    IF @MaxDop IS NULL OR @MaxDop < 0 OR @MaxDop > 64
        THROW 50007, 'MaxDop must be between 0 and 64.', 1;
    IF @StatsGovernanceMode IS NULL OR @StatsGovernanceMode NOT IN ('NONE', 'RECOMMEND', 'ENFORCE')
        THROW 50013, 'StatsGovernanceMode must be NONE, RECOMMEND, or ENFORCE.', 1;
    IF @StatsGovernanceMode <> 'NONE' AND @StatsGovernanceDatabase IS NULL
        THROW 50014, 'StatsGovernanceDatabase is required when StatsGovernanceMode is enabled.', 1;
    IF @StatsGovernanceMode <> 'NONE'
       AND OBJECT_ID(QUOTENAME(@StatsGovernanceDatabase)
           + N'.dbo.usp_DRE_StatsGovernanceTargeted_v1', N'P') IS NULL
        THROW 50015, 'The selected statistics governance database lacks dbo.usp_DRE_StatsGovernanceTargeted_v1.', 1;

    CREATE TABLE #Scope
    (
        database_name sysname NOT NULL,
        schema_name sysname NULL,
        table_name sysname NULL,
        index_name sysname NULL
    );

    IF @Targets IS NOT NULL
    BEGIN
        IF ISJSON(@Targets) <> 1 OR LEFT(LTRIM(@Targets), 1) <> N'['
            THROW 50008, 'Targets must be a JSON array of selector objects.', 1;

        CREATE TABLE #Parsed
        (
            database_name nvarchar(4000) NULL,
            schema_name nvarchar(4000) NULL,
            table_name nvarchar(4000) NULL,
            index_name nvarchar(4000) NULL
        );

        INSERT #Parsed (database_name, schema_name, table_name, index_name)
        SELECT database_name, schema_name, table_name, index_name
        FROM OPENJSON(@Targets)
        WITH
        (
            database_name nvarchar(4000) '$.database',
            schema_name nvarchar(4000) '$.schema',
            table_name nvarchar(4000) '$.table',
            index_name nvarchar(4000) '$.index'
        );

        IF NOT EXISTS (SELECT 1 FROM #Parsed)
            THROW 50009, 'Targets cannot be an empty array.', 1;
        IF EXISTS
        (
            SELECT 1 FROM #Parsed
            WHERE database_name IS NULL OR LEN(database_name) NOT BETWEEN 1 AND 128
               OR (schema_name IS NOT NULL AND LEN(schema_name) NOT BETWEEN 1 AND 128)
               OR (table_name IS NOT NULL AND LEN(table_name) NOT BETWEEN 1 AND 128)
               OR (index_name IS NOT NULL AND LEN(index_name) NOT BETWEEN 1 AND 128)
               OR (table_name IS NOT NULL AND schema_name IS NULL)
               OR (index_name IS NOT NULL AND table_name IS NULL)
        )
            THROW 50010, 'Each selector needs a database; tables need a schema; indexes need a table. Names must be 1-128 characters.', 1;

        INSERT #Scope (database_name, schema_name, table_name, index_name)
        SELECT DISTINCT CONVERT(sysname, database_name), CONVERT(sysname, schema_name),
                        CONVERT(sysname, table_name), CONVERT(sysname, index_name)
        FROM #Parsed;

        IF EXISTS
        (
            SELECT 1 FROM #Scope AS s
            LEFT JOIN sys.databases AS d ON d.name = s.database_name
            WHERE d.database_id IS NULL OR d.database_id <= 4
               OR d.state_desc <> 'ONLINE' OR d.is_read_only = 1
               OR d.source_database_id IS NOT NULL OR ISNULL(HAS_DBACCESS(d.name), 0) <> 1
        )
            THROW 50011, 'A selector names an unknown or system database.', 1;
    END;

    CREATE TABLE #Work
    (
        work_id int IDENTITY(1,1) PRIMARY KEY,
        database_name sysname NOT NULL,
        schema_name sysname NOT NULL,
        table_name sysname NOT NULL,
        index_name sysname NOT NULL,
        partition_number int NOT NULL,
        partition_count int NOT NULL,
        page_count bigint NOT NULL,
        page_fullness decimal(5,2) NULL,
        link_fragmentation decimal(5,2) NULL,
        action_name varchar(10) NOT NULL,
        reason varchar(22) NOT NULL,
        command_text nvarchar(max) NULL,
        status_name varchar(16) NOT NULL DEFAULT ('PLANNED'),
        error_number int NULL,
        error_message nvarchar(4000) NULL
    );

    CREATE TABLE #ScanErrors
    (
        database_name sysname NOT NULL,
        error_number int NOT NULL,
        error_message nvarchar(4000) NOT NULL
    );

    CREATE TABLE #StatsWork
    (
        stats_work_id int IDENTITY(1,1) PRIMARY KEY,
        database_name sysname NOT NULL,
        schema_name sysname NOT NULL,
        table_name sysname NOT NULL,
        command_text nvarchar(max) NOT NULL,
        status_name varchar(16) NOT NULL,
        error_number int NULL,
        error_message nvarchar(4000) NULL
    );

    DECLARE @Db sysname, @Sql nvarchar(max), @LockResult int,
            @AllTargets bit = CASE WHEN @Targets IS NULL THEN 1 ELSE 0 END;
    IF @Execute = 1
    BEGIN
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'usp_DefragIndexes_instance',
            @LockMode = N'Exclusive',
            @LockOwner = N'Session',
            @LockTimeout = 0;
        IF @LockResult < 0
            THROW 50012, 'Another defrag run holds the instance lock.', 1;
    END;

    BEGIN TRY
    DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT d.name
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state_desc = 'ONLINE'
          AND d.is_read_only = 0
          AND d.source_database_id IS NULL
          AND HAS_DBACCESS(d.name) = 1
          AND (@Targets IS NULL OR EXISTS (SELECT 1 FROM #Scope AS s WHERE s.database_name = d.name))
        ORDER BY d.name;

    OPEN db_cursor;
    FETCH NEXT FROM db_cursor INTO @Db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @Sql = N'USE ' + QUOTENAME(@Db) + N';
                CREATE TABLE #SelectedIndexes (object_id int NOT NULL, index_id int NOT NULL,
                    PRIMARY KEY (object_id, index_id));

                INSERT #SelectedIndexes (object_id, index_id)
                SELECT i.object_id, i.index_id
                FROM sys.indexes AS i
                JOIN sys.tables AS t ON t.object_id = i.object_id
                JOIN sys.schemas AS sch ON sch.schema_id = t.schema_id
                WHERE i.type IN (1, 2)
                  AND i.is_disabled = 0
                  AND i.is_hypothetical = 0
                  AND t.is_memory_optimized = 0
                  AND i.name IS NOT NULL
                  AND EXISTS
                  (
                      SELECT 1 FROM sys.dm_db_partition_stats AS approximate
                      WHERE approximate.object_id = i.object_id
                        AND approximate.index_id = i.index_id
                        AND approximate.in_row_data_page_count >= @MinPages
                  )
                  AND (@AllTargets = 1 OR EXISTS
                  (
                      SELECT 1 FROM #Scope AS s
                      WHERE s.database_name COLLATE DATABASE_DEFAULT = @DbName
                        AND (s.schema_name IS NULL OR s.schema_name COLLATE DATABASE_DEFAULT = sch.name)
                        AND (s.table_name IS NULL OR s.table_name COLLATE DATABASE_DEFAULT = t.name)
                        AND (s.index_name IS NULL OR s.index_name COLLATE DATABASE_DEFAULT = i.name)
                  ));

                ;WITH partition_counts AS
                (
                    SELECT object_id, index_id, COUNT(*) AS partition_count
                    FROM sys.partitions
                    GROUP BY object_id, index_id
                )
                INSERT #Work
                (
                    database_name, schema_name, table_name, index_name,
                    partition_number, partition_count, page_count, page_fullness,
                    link_fragmentation, action_name, reason
                )
                SELECT @DbName, sch.name, t.name, i.name, ps.partition_number,
                       pc.partition_count, ps.page_count,
                       CONVERT(decimal(5,2), ps.avg_page_space_used_in_percent),
                       CONVERT(decimal(5,2), ps.avg_fragmentation_in_percent),
                       CASE WHEN @Criterion = ''PAGE_FULLNESS''
                                      OR i.allow_page_locks = 0
                                      OR ps.avg_fragmentation_in_percent >= @RebuildAt
                            THEN ''REBUILD'' ELSE ''REORGANIZE'' END,
                       @Criterion
                FROM #SelectedIndexes AS selected
                JOIN sys.indexes AS i ON i.object_id = selected.object_id AND i.index_id = selected.index_id
                JOIN sys.tables AS t ON t.object_id = i.object_id
                JOIN sys.schemas AS sch ON sch.schema_id = t.schema_id
                JOIN partition_counts AS pc ON pc.object_id = i.object_id AND pc.index_id = i.index_id
                CROSS APPLY sys.dm_db_index_physical_stats(DB_ID(), selected.object_id,
                    selected.index_id, NULL, ''SAMPLED'') AS ps
                WHERE ps.index_level = 0
                  AND ps.alloc_unit_type_desc = ''IN_ROW_DATA''
                  AND ps.page_count >= @MinPages
                  AND ((@Criterion = ''PAGE_FULLNESS''
                        AND ps.avg_page_space_used_in_percent < @MinFullness
                        AND (i.fill_factor = 0 OR i.fill_factor >= @MinFullness))
                    OR (@Criterion = ''PAGE_LINK''
                        AND ps.avg_fragmentation_in_percent >= @MinLink));';

            EXEC sys.sp_executesql @Sql,
                N'@DbName sysname, @MinFullness decimal(5,2), @MinLink decimal(5,2),
                  @RebuildAt decimal(5,2), @MinPages int, @Criterion varchar(16), @AllTargets bit',
                @DbName = @Db, @MinFullness = @MinPageFullness,
                @MinLink = @MinLinkFragmentation, @RebuildAt = @RebuildAtFragmentation,
                @MinPages = @MinPageCount, @Criterion = @Criterion,
                @AllTargets = @AllTargets;
        END TRY
        BEGIN CATCH
            INSERT #ScanErrors (database_name, error_number, error_message)
            VALUES (@Db, ERROR_NUMBER(), ERROR_MESSAGE());
        END CATCH;
        FETCH NEXT FROM db_cursor INTO @Db;
    END;
    CLOSE db_cursor;
    DEALLOCATE db_cursor;

    /* Deterministic work cap: largest qualifying partitions first. */
    IF @MaxOperations IS NOT NULL
    BEGIN
        ;WITH ranked AS
        (
            SELECT work_id, ROW_NUMBER() OVER
                (ORDER BY page_count DESC, database_name, schema_name, table_name,
                          index_name, partition_number) AS rn
            FROM #Work
        )
        UPDATE w SET status_name = 'DEFERRED'
        FROM #Work AS w
        JOIN ranked AS r ON r.work_id = w.work_id
        WHERE r.rn > @MaxOperations;
    END;

    DECLARE @WorkId int, @Schema sysname, @Table sysname, @Index sysname,
            @Partition int, @PartitionCount int, @Action varchar(10), @Command nvarchar(max);
    DECLARE work_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT work_id, database_name, schema_name, table_name, index_name,
               partition_number, partition_count, action_name
        FROM #Work
        WHERE status_name = 'PLANNED'
        ORDER BY page_count DESC, database_name, schema_name, table_name,
                 index_name, partition_number;

    OPEN work_cursor;
    FETCH NEXT FROM work_cursor INTO @WorkId, @Db, @Schema, @Table, @Index,
                                     @Partition, @PartitionCount, @Action;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Command = N'ALTER INDEX ' + QUOTENAME(@Index)
            + N' ON ' + QUOTENAME(@Schema) + N'.' + QUOTENAME(@Table)
            + N' ' + @Action;
        IF @PartitionCount > 1
            SET @Command += N' PARTITION = ' + CONVERT(nvarchar(11), @Partition);
        IF @Action = 'REBUILD'
            SET @Command += N' WITH (MAXDOP = ' + CONVERT(nvarchar(11), @MaxDop)
                + CASE WHEN @OnlineRebuild = 1 THEN N', ONLINE = ON' ELSE N'' END + N')';
        SET @Command += N';';

        UPDATE #Work SET command_text = N'USE ' + QUOTENAME(@Db) + N'; ' + @Command
        WHERE work_id = @WorkId;

        IF @Execute = 1
        BEGIN
            BEGIN TRY
                SET @Sql = N'USE ' + QUOTENAME(@Db) + N'; ' + @Command;
                EXEC sys.sp_executesql @Sql;
                UPDATE #Work SET status_name = 'SUCCEEDED' WHERE work_id = @WorkId;
            END TRY
            BEGIN CATCH
                UPDATE #Work
                SET status_name = 'FAILED', error_number = ERROR_NUMBER(),
                    error_message = ERROR_MESSAGE()
                WHERE work_id = @WorkId;
            END CATCH;
        END;

        FETCH NEXT FROM work_cursor INTO @WorkId, @Db, @Schema, @Table, @Index,
                                         @Partition, @PartitionCount, @Action;
    END;
    CLOSE work_cursor;
    DEALLOCATE work_cursor;

    IF @StatsGovernanceMode <> 'NONE'
    BEGIN
        ;WITH reorganized_tables AS
        (
            SELECT DISTINCT database_name, schema_name, table_name
            FROM #Work
            WHERE action_name = 'REORGANIZE' AND status_name <> 'DEFERRED'
        )
        INSERT #StatsWork
            (database_name, schema_name, table_name, command_text, status_name)
        SELECT database_name, schema_name, table_name,
               N'EXEC ' + QUOTENAME(@StatsGovernanceDatabase)
                   + N'.dbo.usp_DRE_StatsGovernanceTargeted_v1 '
                   + N'@Databases=@pDatabase, @Tables=@pTable, '
                   + N'@StatisticsScope=''INDEX_ONLY'', @Mode=@pMode;',
               CASE WHEN @Execute = 1 THEN 'SKIPPED' ELSE 'PLANNED' END
        FROM reorganized_tables;

        IF @Execute = 1
        BEGIN
            DECLARE @StatsWorkId int,
                    @StatsDatabase sysname, @StatsSchema sysname, @StatsTable sysname,
                    @SchemaTable nvarchar(517);
            DECLARE stats_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT sw.stats_work_id, sw.database_name, sw.schema_name, sw.table_name
                FROM #StatsWork AS sw
                WHERE EXISTS
                (
                    SELECT 1 FROM #Work AS w
                    WHERE w.database_name = sw.database_name
                      AND w.schema_name = sw.schema_name
                      AND w.table_name = sw.table_name
                      AND w.action_name = 'REORGANIZE'
                      AND w.status_name = 'SUCCEEDED'
                );
            OPEN stats_cursor;
            FETCH NEXT FROM stats_cursor INTO @StatsWorkId, @StatsDatabase,
                                              @StatsSchema, @StatsTable;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY
                    SET @SchemaTable = QUOTENAME(@StatsSchema) + N'.' + QUOTENAME(@StatsTable);
                    SET @Sql = N'EXEC ' + QUOTENAME(@StatsGovernanceDatabase)
                        + N'.dbo.usp_DRE_StatsGovernanceTargeted_v1 '
                        + N'@Databases=@pDatabase, @Tables=@pTable, '
                        + N'@StatisticsScope=''INDEX_ONLY'', @Mode=@pMode;';
                    EXEC sys.sp_executesql @Sql,
                        N'@pDatabase nvarchar(max), @pTable nvarchar(max), @pMode varchar(10)',
                        @pDatabase = @StatsDatabase, @pTable = @SchemaTable,
                        @pMode = @StatsGovernanceMode;
                    UPDATE #StatsWork SET status_name = 'DELEGATED'
                    WHERE stats_work_id = @StatsWorkId;
                END TRY
                BEGIN CATCH
                    UPDATE #StatsWork
                    SET status_name = 'FAILED', error_number = ERROR_NUMBER(),
                        error_message = ERROR_MESSAGE()
                    WHERE stats_work_id = @StatsWorkId;
                END CATCH;
                FETCH NEXT FROM stats_cursor INTO @StatsWorkId, @StatsDatabase,
                                                  @StatsSchema, @StatsTable;
            END;
            CLOSE stats_cursor;
            DEALLOCATE stats_cursor;
        END;
    END;

    IF @Execute = 1
        EXEC sys.sp_releaseapplock
            @Resource = N'usp_DefragIndexes_instance', @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        IF @Execute = 1
            EXEC sys.sp_releaseapplock
                @Resource = N'usp_DefragIndexes_instance', @LockOwner = N'Session';
        THROW;
    END CATCH;

    SELECT database_name, schema_name, table_name, index_name, partition_number,
           page_count, page_fullness, link_fragmentation, reason, action_name,
           status_name, command_text, error_number, error_message
    FROM #Work
    ORDER BY page_count DESC, database_name, schema_name, table_name,
             index_name, partition_number;

    SELECT database_name, error_number, error_message
    FROM #ScanErrors
    ORDER BY database_name;

    SELECT database_name, schema_name, table_name,
           @StatsGovernanceMode AS governance_mode,
           status_name, command_text, error_number, error_message
    FROM #StatsWork
    ORDER BY database_name, schema_name, table_name;
END;
GO
