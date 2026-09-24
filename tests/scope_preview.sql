/* Read-only scope checks. Run in the administration database. */
PRINT 'Table selector';
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @RebuildAtFragmentation = 100,
    @MinPageCount = 100;

/* This threshold intentionally exceeds all current test-instance indexes. */
PRINT 'Database selector';
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @MinPageCount = 200000;

PRINT 'Instance selector';
EXEC dbo.usp_DefragIndexes
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @MinPageCount = 200000;
GO
