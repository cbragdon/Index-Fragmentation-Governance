/* Run in the administration database after installing the procedure. */
PRINT 'PAGE_LINK preview';
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive","index":"PK_TransactionHistoryArchive_TransactionID"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @RebuildAtFragmentation = 100,
    @MinPageCount = 100;

PRINT 'PAGE_FULLNESS preview';
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive","index":"PK_TransactionHistoryArchive_TransactionID"}]',
    @Criterion = 'PAGE_FULLNESS',
    @MinPageFullness = 99.50,
    @MinPageCount = 100;

PRINT 'PAGE_LINK execution';
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive","index":"PK_TransactionHistoryArchive_TransactionID"}]',
    @Criterion = 'PAGE_LINK',
    @MinLinkFragmentation = 0,
    @RebuildAtFragmentation = 100,
    @MinPageCount = 100,
    @Execute = 1;

PRINT 'PAGE_FULLNESS execution';
EXEC dbo.usp_DefragIndexes
    @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive","index":"PK_TransactionHistoryArchive_TransactionID"}]',
    @Criterion = 'PAGE_FULLNESS',
    @MinPageFullness = 99.99,
    @MinPageCount = 100,
    @Execute = 1;
GO
