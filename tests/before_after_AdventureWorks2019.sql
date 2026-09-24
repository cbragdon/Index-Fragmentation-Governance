/*
    Run in SSMS or with sqlcmd after installing dbo.usp_DefragIndexes in
    StatsGovernanceTest. Replace StatsGovernanceTest below if you installed it
    in a different administration database.

    Creates only dbo.DefragGovernanceDemo in AdventureWorks2019. Run once;
    the table remains available for inspection until you drop it explicitly.
*/
USE AdventureWorks2019;
GO
SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.DefragGovernanceDemo', N'U') IS NOT NULL
    THROW 51000, 'dbo.DefragGovernanceDemo already exists. Inspect or drop it before rerunning setup.', 1;

CREATE TABLE dbo.DefragGovernanceDemo
(
    DemoId int IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_DefragGovernanceDemo PRIMARY KEY CLUSTERED,
    RandomKey uniqueidentifier NOT NULL,
    Payload char(400) NOT NULL
);

CREATE INDEX IX_DefragGovernanceDemo_Link
    ON dbo.DefragGovernanceDemo (RandomKey) INCLUDE (Payload);
CREATE INDEX IX_DefragGovernanceDemo_Fullness
    ON dbo.DefragGovernanceDemo (DemoId) INCLUDE (Payload);

INSERT dbo.DefragGovernanceDemo (RandomKey, Payload)
SELECT TOP (20000) NEWID(), REPLICATE('x', 400)
FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b;

DELETE dbo.DefragGovernanceDemo WHERE DemoId % 4 = 0;

CREATE TABLE #Measurements
(
    test_name varchar(16) NOT NULL,
    phase_name varchar(6) NOT NULL,
    index_name sysname NOT NULL,
    page_count bigint NOT NULL,
    page_fullness decimal(6,2) NULL,
    link_fragmentation decimal(6,2) NULL,
    stats_last_updated datetime2(7) NULL
);

/* PAGE_LINK: measure, preview, execute, and measure again. */
INSERT #Measurements
SELECT 'PAGE_LINK', 'BEFORE', i.name, ps.page_count,
       ps.avg_page_space_used_in_percent, ps.avg_fragmentation_in_percent,
       properties.last_updated
FROM sys.indexes AS i
CROSS APPLY sys.dm_db_index_physical_stats
    (DB_ID(), OBJECT_ID(N'dbo.DefragGovernanceDemo'), i.index_id, NULL, 'DETAILED') AS ps
OUTER APPLY sys.dm_db_stats_properties(i.object_id, i.index_id) AS properties
WHERE i.object_id = OBJECT_ID(N'dbo.DefragGovernanceDemo')
  AND i.name = N'IX_DefragGovernanceDemo_Link'
  AND ps.index_level = 0 AND ps.alloc_unit_type_desc = 'IN_ROW_DATA';

PRINT 'PAGE_LINK preview';
EXEC StatsGovernanceTest.dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"dbo","table":"DefragGovernanceDemo","index":"IX_DefragGovernanceDemo_Link"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @RebuildAtFragmentation = 100,
    @MinPageCount = 100,
    @StatsGovernanceDatabase = N'DBAdmin',
    @StatsGovernanceMode = 'RECOMMEND';

PRINT 'PAGE_LINK execution';
EXEC StatsGovernanceTest.dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"dbo","table":"DefragGovernanceDemo","index":"IX_DefragGovernanceDemo_Link"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @RebuildAtFragmentation = 100,
    @MinPageCount = 100,
    @StatsGovernanceDatabase = N'DBAdmin',
    @StatsGovernanceMode = 'RECOMMEND',
    @Execute = 1;

INSERT #Measurements
SELECT 'PAGE_LINK', 'AFTER', i.name, ps.page_count,
       ps.avg_page_space_used_in_percent, ps.avg_fragmentation_in_percent,
       properties.last_updated
FROM sys.indexes AS i
CROSS APPLY sys.dm_db_index_physical_stats
    (DB_ID(), OBJECT_ID(N'dbo.DefragGovernanceDemo'), i.index_id, NULL, 'DETAILED') AS ps
OUTER APPLY sys.dm_db_stats_properties(i.object_id, i.index_id) AS properties
WHERE i.object_id = OBJECT_ID(N'dbo.DefragGovernanceDemo')
  AND i.name = N'IX_DefragGovernanceDemo_Link'
  AND ps.index_level = 0 AND ps.alloc_unit_type_desc = 'IN_ROW_DATA';

/* PAGE_FULLNESS: measure, preview, execute, and measure again. */
INSERT #Measurements
SELECT 'PAGE_FULLNESS', 'BEFORE', i.name, ps.page_count,
       ps.avg_page_space_used_in_percent, ps.avg_fragmentation_in_percent,
       properties.last_updated
FROM sys.indexes AS i
CROSS APPLY sys.dm_db_index_physical_stats
    (DB_ID(), OBJECT_ID(N'dbo.DefragGovernanceDemo'), i.index_id, NULL, 'DETAILED') AS ps
OUTER APPLY sys.dm_db_stats_properties(i.object_id, i.index_id) AS properties
WHERE i.object_id = OBJECT_ID(N'dbo.DefragGovernanceDemo')
  AND i.name = N'IX_DefragGovernanceDemo_Fullness'
  AND ps.index_level = 0 AND ps.alloc_unit_type_desc = 'IN_ROW_DATA';

PRINT 'PAGE_FULLNESS preview';
EXEC StatsGovernanceTest.dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"dbo","table":"DefragGovernanceDemo","index":"IX_DefragGovernanceDemo_Fullness"}]',
    @Criterion = 'PAGE_FULLNESS',
    @MinPageFullness = 99.99,
    @MinPageCount = 100;

PRINT 'PAGE_FULLNESS execution';
EXEC StatsGovernanceTest.dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"dbo","table":"DefragGovernanceDemo","index":"IX_DefragGovernanceDemo_Fullness"}]',
    @Criterion = 'PAGE_FULLNESS',
    @MinPageFullness = 99.99,
    @MinPageCount = 100,
    @Execute = 1;

INSERT #Measurements
SELECT 'PAGE_FULLNESS', 'AFTER', i.name, ps.page_count,
       ps.avg_page_space_used_in_percent, ps.avg_fragmentation_in_percent,
       properties.last_updated
FROM sys.indexes AS i
CROSS APPLY sys.dm_db_index_physical_stats
    (DB_ID(), OBJECT_ID(N'dbo.DefragGovernanceDemo'), i.index_id, NULL, 'DETAILED') AS ps
OUTER APPLY sys.dm_db_stats_properties(i.object_id, i.index_id) AS properties
WHERE i.object_id = OBJECT_ID(N'dbo.DefragGovernanceDemo')
  AND i.name = N'IX_DefragGovernanceDemo_Fullness'
  AND ps.index_level = 0 AND ps.alloc_unit_type_desc = 'IN_ROW_DATA';

SELECT before.test_name, before.index_name,
       before.page_count AS pages_before, after.page_count AS pages_after,
       before.page_fullness AS fullness_before, after.page_fullness AS fullness_after,
       before.link_fragmentation AS link_before, after.link_fragmentation AS link_after,
       before.stats_last_updated AS stats_updated_before,
       after.stats_last_updated AS stats_updated_after
FROM #Measurements AS before
JOIN #Measurements AS after
  ON after.test_name = before.test_name
 AND after.index_name = before.index_name
 AND after.phase_name = 'AFTER'
WHERE before.phase_name = 'BEFORE'
ORDER BY before.test_name;
GO

/* Optional cleanup, run separately after reviewing the measurements:
USE AdventureWorks2019;
DROP TABLE dbo.DefragGovernanceDemo;
*/
