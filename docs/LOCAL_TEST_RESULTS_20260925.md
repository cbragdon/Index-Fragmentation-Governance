# Local SQL Server validation — 2026-09-25

Installed the revised `sql/usp_DefragIndexes.sql` in `StatsGovernanceTest` on the local SQL Server instance. Tested the default `PAGE_FULLNESS` threshold against the existing `AdventureWorks2019.dbo.DefragGovernanceDemo` table.

| Index | Preview | Execute | Pages before → after | Average fullness before → after | Index statistic last updated |
| --- | --- | --- | --- | --- | --- |
| `PK_DefragGovernanceDemo` | `REORGANIZE`, `PLANNED` | `REORGANIZE`, `SUCCEEDED` | 1,112 → 834 | 73.80% → 98.41% | `NULL` → `NULL` |

The preview and execution omitted `@MinPageFullness`, so both exercised its new 90% default. A second preview after the reorganization returned no candidate. The index's statistic remained unchanged, as expected for `REORGANIZE` with the default `@StatsGovernanceMode = 'NONE'`.
