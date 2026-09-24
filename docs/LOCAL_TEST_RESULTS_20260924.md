# Local SQL Server validation — 2026-09-24

Local SQL Server 2025 instance. Defrag procedure installed for testing in `StatsGovernanceTest`. Statistics Governance v1.3.2 was already installed in `DBAdmin`. All commands used Windows Authentication.

## Dedicated AdventureWorks2019 demo

Executed `tests/before_after_AdventureWorks2019.sql` against a newly created `AdventureWorks2019.dbo.DefragGovernanceDemo` table. The script leaves this lab table in place for inspection.

| Criterion | Index | Action | Pages before → after | Fullness before → after | Link fragmentation before → after | Statistics last updated before → after |
| --- | --- | --- | --- | --- | --- | --- |
| `PAGE_LINK` | `IX_DefragGovernanceDemo_Link` | `REORGANIZE` succeeded | 1,112 → 837 | 97.75% → 97.40% | 0.18% → 0.12% | NULL → NULL |
| `PAGE_FULLNESS` | `IX_DefragGovernanceDemo_Fullness` | `REBUILD` succeeded | 1,053 → 790 | 74.60% → 96.16% | 0.09% → 0% | NULL → 2026-09-24 19:22:25 local |

The page-link action delegated to `DBAdmin.dbo.usp_DRE_StatsGovernanceTargeted_v1` in `RECOMMEND` mode with `INDEX_ONLY` scope. Governance RunID `11B0854E-45DE-4E64-B8A2-A31A777583A1` completed. It returned three index-associated statistics for the demo table and marked each ineligible with `BELOW_ROWCOUNT_FLOOR` because the table had 15,000 rows. No `DBAdmin.dbo.CommandLog` rows were written for this table. This verifies the governance policy decided against a statistics update; `DELEGATED` does not mean a statistic was updated.

## Scope regression

Executed `tests/scope_preview.sql` after compiling the revised procedure. Table targeting returned the three expected `Production.TransactionHistoryArchive` indexes. Database and instance previews completed without scan errors using a deliberately high 200,000-page threshold and returned no candidates. No indexes were changed by those previews.

## Limits

The live handoff test exercised `RECOMMEND`, not `ENFORCE`. The `ENFORCE` path still requires a dedicated approved Stats Governance lab scenario and per-statistic telemetry review. The database and instance scope checks validated traversal and filtering but did not execute maintenance at those scopes.
