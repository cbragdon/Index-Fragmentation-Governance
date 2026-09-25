# Deployment

This repository contains source and examples for `dbo.usp_DefragIndexes`. Installing the procedure is separate from publishing this Git repository to GitHub.

## SQL Server installation

1. Choose an existing administration database with compatibility level 130 or higher on SQL Server 2016 SP1 or later.
2. Install or upgrade the procedure from the repository root:

   ```powershell
   sqlcmd -S YourServer -d YourAdminDatabase -E -b -i .\sql\usp_DefragIndexes.sql
   ```

3. Preview a narrow target and inspect the generated commands:

   ```sql
   EXEC dbo.usp_DefragIndexes
       @Targets = N'[{"database":"AdventureWorks2019","schema":"Production","table":"TransactionHistoryArchive"}]',
       @Criterion = 'PAGE_LINK';
   ```

4. Set `@Execute = 1` only for the scope you intend to maintain. The default is preview only.

For statistics updates after a reorganize, first install [Stats Governance](https://github.com/cbragdon/StatsGovernance) in a utility database using its [installation instructions](https://github.com/cbragdon/StatsGovernance#install). Verify that `dbo.usp_DRE_StatsGovernanceTargeted_v1` exists there, then pass that database as `@StatsGovernanceDatabase`. `RECOMMEND` reports decisions only; `ENFORCE` may update eligible index statistics subject to that engine's approval and eligibility rules. With the default mode `NONE`, no handoff occurs. Rebuilds refresh their own index statistics without Stats Governance. No Stats Governance objects are installed by this repository. The defrag installer reports whether it can find the targeted procedure in an accessible online database and prints the repository URL when it cannot; this check does not block installation.

## GitHub publication

This directory can be initialized as a Git repository and connected to a GitHub repository URL chosen by the owner. Check the files and local test record before publishing. Do not commit SQL credentials or connection strings containing secrets.

```powershell
git init -b main
git add .
git commit -m "Initial index fragmentation governance process"
git remote add origin https://github.com/OWNER/REPOSITORY.git
git push -u origin main
```

Replace `OWNER/REPOSITORY` with the actual GitHub repository. The remote URL is intentionally not embedded in this project.
