# Review Insights: a Snowflake data pipeline for Spotify app reviews

A project built while learning Snowflake: load about 61k Spotify app reviews from a raw CSV into Snowflake, profile and clean them with SQL, and prepare them for AI analysis.

```
CSV file -> Stage -> RAW table -> CLEAN view -> (AI enrichment: blocked on trial) -> dashboard (planned)
```

## Status
**Stopped at the AI step.** The data pipeline (Steps 1 and 2) is complete and working. The AI enrichment step could not run because Snowflake trial accounts block the Cortex AI functions: the legacy `SNOWFLAKE.CORTEX.SENTIMENT` is blocked for new accounts, and its replacements `AI_SENTIMENT`, `AI_CLASSIFY` and `AI_COMPLETE` all return "not available for trial accounts". Steps 3 to 5 are written as a workaround (train our own model instead of calling Snowflake's AI) but have not been run yet.

## Dataset
Spotify App Reviews 2022 (Kaggle): about 61k Google Play reviews of the Spotify app in one CSV. Columns: `Time_submitted, Review, Rating, Total_thumbsup, Reply`.

## What was built
| Layer | Object | Type |
|---|---|---|
| Compute | `REVIEWS_WH` (X-Small, auto-suspend 60 s) | Warehouse |
| Ingestion | `RAW.REVIEWS_STAGE`, `RAW.REVIEWS_CSV` | Internal stage, file format |
| Raw | `RAW.RAW_REVIEWS` | Table, data exactly as loaded |
| Clean | `ANALYTICS.CLEAN_REVIEWS` | View: typed timestamps, trimmed text, word count, dedupe, stable `review_id` (MD5) |

## Findings
- **Load:** 61,590 rows loaded. 4 malformed CSV lines were skipped with `ON_ERROR = 'CONTINUE'` and inspected with `VALIDATE`, rather than failing the whole load.
- **Data quality:** profiling found no unparseable dates, empty reviews, invalid ratings or duplicates, so cleaning removed 0 rows (61,590 raw, 61,590 clean).
- **Ratings are polarized:** 1 star 28.7% (17,652), 2 stars 11.6% (7,117), 3 stars 11.2% (6,885), 4 stars 12.7% (7,842), 5 stars 35.9% (22,094). Almost two thirds of reviews are 1 or 5 stars.
- **Date range:** 2022-01-01 to 2022-07-09, about 6 months. July is a partial month, so monthly review counts drop there for that reason only.

## Files
| # | File | Status | What it covers |
|---|------|--------|----------------|
| 1 | `01_setup_loadSQL.sql` | Done | Warehouse, database/schemas, file format, stage, `COPY INTO` with validation |
| 2 | `02_clean.sql` | Done | Data profiling, `TRY_TO_TIMESTAMP`, `QUALIFY ROW_NUMBER()` dedupe, views vs tables |
| 3 | `03_AI_enrich.sql` | Blocked | Original AI step using Snowflake Cortex functions; fails on trial accounts |
| 3 (workaround) | `03_topics.sql` | Not run | Rule-based topic tagging with text normalization, arrays and `FLATTEN` |
| 4 | `04_sentiment_model.py` | Not run | Snowflake Notebook: train a scikit-learn sentiment model on star ratings, evaluate it, write predictions back |
| 5 | `05_insights.sql` | Not run | Join predictions and topics, insight queries |
| 6 | Streamlit dashboard | Not written | |

## What I learned
- Snowflake separates storage from compute; warehouses only cost credits while running.
- Keep a RAW layer exactly as loaded and do typing and cleaning in a separate layer.
- Validate loads before running them, and handle bad rows explicitly instead of failing the whole job.
- Profile data before cleaning it, so you know what is actually wrong.
- Views for cheap logic, tables for expensive results.
- Check platform limits early: the AI features this project depended on are not available on a trial account.

## Next steps
1. Run `03_topics.sql`, the `04_sentiment_model.py` notebook and `05_insights.sql`, or use a paid Snowflake account to run the original Cortex AI version.
2. Build a Streamlit in Snowflake dashboard on top of `ANALYTICS.ENRICHED_REVIEWS`.
