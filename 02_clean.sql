-- =====================================================================
-- STEP 2: Clean the data
-- Goal: turn RAW_REVIEWS (exactly as loaded) into a clean, typed,
-- de-duplicated view in the ANALYTICS schema that Steps 3 and 4 use.
-- Open a new SQL file in Workspaces, paste this, and run one statement
-- at a time again.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE REVIEWS_WH;
USE SCHEMA REVIEWS_DB.RAW;

-- ---------------------------------------------------------------------
-- 2a. PROFILE THE DATA FIRST
-- Before cleaning anything, measure what's wrong. Each query answers
-- one question. Write the numbers down; they go in your README.
-- ---------------------------------------------------------------------

-- What do the dates look like?
SELECT time_submitted FROM RAW_REVIEWS LIMIT 5;

-- How many dates can't be turned into a real timestamp?
-- TRY_TO_TIMESTAMP returns NULL instead of erroring on a bad value.
-- (TO_TIMESTAMP would crash the whole query on the first bad one.)
SELECT COUNT(*) AS bad_dates
FROM RAW_REVIEWS
WHERE TRY_TO_TIMESTAMP(time_submitted) IS NULL;

-- Empty or whitespace-only reviews (useless for AI analysis)
SELECT COUNT(*) AS empty_reviews
FROM RAW_REVIEWS
WHERE review IS NULL OR TRIM(review) = '';

-- Ratings outside 1 to 5 (should be 0)
SELECT COUNT(*) AS bad_ratings
FROM RAW_REVIEWS
WHERE rating NOT BETWEEN 1 AND 5 OR rating IS NULL;

-- Exact duplicates: same text posted at the same time.
-- GROUP BY + HAVING COUNT(*) > 1 = "show groups that appear more than once"
SELECT time_submitted, review, COUNT(*) AS copies
FROM RAW_REVIEWS
GROUP BY time_submitted, review
HAVING COUNT(*) > 1
ORDER BY copies DESC
LIMIT 10;

-- Very short reviews like "good" or "ok". We keep them, but flag them:
-- the AI has little to work with in 1 or 2 words.
SELECT COUNT(*) AS very_short_reviews
FROM RAW_REVIEWS
WHERE ARRAY_SIZE(SPLIT(TRIM(review), ' ')) <= 3;

-- ---------------------------------------------------------------------
-- 2b. THE CLEAN VIEW
--
-- VIEW vs TABLE:
--   A TABLE stores a copy of the data.
--   A VIEW stores only the SQL query; it runs fresh each time you read it.
-- A view is perfect here: no duplicate storage, and if RAW_REVIEWS gets
-- new rows, the clean view includes them automatically.
-- (In Step 3 we'll use a TABLE instead, and you'll see why.)
--
-- What each line does is commented inline.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW REVIEWS_DB.ANALYTICS.CLEAN_REVIEWS AS
SELECT
    -- A stable unique ID for each review, built from its contents.
    -- MD5 turns any text into a fixed 32-character fingerprint, so the
    -- same review always gets the same ID. Step 3 joins on this.
    MD5(time_submitted || '|' || review)          AS review_id,

    TRY_TO_TIMESTAMP(time_submitted)              AS submitted_at,
    TRY_TO_TIMESTAMP(time_submitted)::DATE        AS review_date,
    DATE_TRUNC('month', TRY_TO_TIMESTAMP(time_submitted))::DATE
                                                  AS review_month,

    TRIM(review)                                  AS review_text,
    ARRAY_SIZE(SPLIT(TRIM(review), ' '))          AS word_count,
    rating,
    COALESCE(total_thumbsup, 0)                   AS thumbs_up,   -- NULL -> 0
    reply IS NOT NULL                             AS spotify_replied
FROM REVIEWS_DB.RAW.RAW_REVIEWS
WHERE review IS NOT NULL
  AND TRIM(review) <> ''
  AND rating BETWEEN 1 AND 5
  AND TRY_TO_TIMESTAMP(time_submitted) IS NOT NULL
-- QUALIFY filters on a window function, like WHERE but applied after.
-- ROW_NUMBER numbers the rows inside each group of identical reviews
-- (1, 2, 3...). Keeping only row 1 = keep one copy of each duplicate.
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY time_submitted, review
    ORDER BY total_thumbsup DESC NULLS LAST
) = 1;

-- ---------------------------------------------------------------------
-- 2c. CHECK THE RESULT
-- ---------------------------------------------------------------------
USE SCHEMA REVIEWS_DB.ANALYTICS;

-- Raw vs clean: the difference is exactly the rows we removed.
SELECT
    (SELECT COUNT(*) FROM REVIEWS_DB.RAW.RAW_REVIEWS) AS raw_rows,
    (SELECT COUNT(*) FROM CLEAN_REVIEWS)              AS clean_rows,
    raw_rows - clean_rows                             AS removed;

-- review_id must be unique (should return no rows)
SELECT review_id, COUNT(*)
FROM CLEAN_REVIEWS
GROUP BY review_id
HAVING COUNT(*) > 1;

-- First real insight! Reviews and average rating per month.
-- Click "Chart" above the results to see it as a line chart.
SELECT review_month,
       COUNT(*)               AS reviews,
       ROUND(AVG(rating), 2)  AS avg_rating
FROM CLEAN_REVIEWS
GROUP BY review_month
ORDER BY review_month;

-- Watch out: the data ends on 2022-07-09, so July has only 9 days.
-- Its review COUNT will look like a crash, but that's a partial month,
-- not a real drop. Averages (avg_rating) are still fair to compare.
-- With only ~6 months of data, weeks give a more detailed picture:
SELECT DATE_TRUNC('week', submitted_at)::DATE AS review_week,
       COUNT(*)               AS reviews,
       ROUND(AVG(rating), 2)  AS avg_rating
FROM CLEAN_REVIEWS
GROUP BY review_week
ORDER BY review_week;

SELECT * FROM CLEAN_REVIEWS LIMIT 10;
