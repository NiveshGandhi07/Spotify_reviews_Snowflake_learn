-- =====================================================================
-- STEP 1: Set up Snowflake and load the raw data
-- Dataset: Spotify App Reviews 2022 (Kaggle), one CSV, ~61k reviews.
-- Run this in Snowsight: left sidebar > Workspaces > + Add new > SQL File.
-- Run one statement at a time with Ctrl/Cmd + Enter so you can see
-- what each one does.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1a. ROLE
-- A role is a bundle of permissions. In a trial you own the account,
-- so ACCOUNTADMIN can do everything. (In a real company you'd use a
-- smaller role.)
-- ---------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- ---------------------------------------------------------------------
-- 1b. WAREHOUSE = the compute (the "engine" that runs queries)
-- Snowflake keeps storage and compute separate. Your data sits in
-- storage for almost free; you pay credits only while a warehouse
-- is running.
--   XSMALL         = smallest size, 1 credit/hour, plenty for us
--   AUTO_SUSPEND   = shut down after 60 s idle (saves credits)
--   AUTO_RESUME    = wake up automatically when you run a query
-- ---------------------------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS REVIEWS_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND   = 60
  AUTO_RESUME    = TRUE;

USE WAREHOUSE REVIEWS_WH;

-- ---------------------------------------------------------------------
-- 1c. DATABASE and SCHEMAS = folders for your tables
-- Full name of any table is DATABASE.SCHEMA.TABLE.
-- We use two schemas, a common data-engineering pattern:
--   RAW       = data exactly as it arrived, never edited
--   ANALYTICS = cleaned + AI-enriched data the app reads
-- ---------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS REVIEWS_DB;
CREATE SCHEMA   IF NOT EXISTS REVIEWS_DB.RAW;
CREATE SCHEMA   IF NOT EXISTS REVIEWS_DB.ANALYTICS;

USE SCHEMA REVIEWS_DB.RAW;

-- ---------------------------------------------------------------------
-- 1d. Turn on Cortex (Snowflake's AI functions) for any region.
-- If your account's region doesn't host a model we need, this lets
-- Snowflake run it in another region. Harmless if not needed.
-- ---------------------------------------------------------------------
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION';

-- ---------------------------------------------------------------------
-- 1e. FILE FORMAT = instructions for reading the CSV
-- Review text contains commas and line breaks, so text fields are
-- wrapped in double quotes. We tell Snowflake that, and to skip the
-- header row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FILE FORMAT REVIEWS_CSV
  TYPE = 'CSV'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL')
  EMPTY_FIELD_AS_NULL = TRUE;

-- ---------------------------------------------------------------------
-- 1f. STAGE = a landing zone for files inside Snowflake
-- Files go: your laptop -> stage -> table.
-- (Real pipelines often use an "external stage" pointing at S3/Azure/GCS;
-- this one is "internal", stored by Snowflake.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE STAGE REVIEWS_STAGE
  FILE_FORMAT = REVIEWS_CSV;

-- >>> NOW UPLOAD THE FILE (do this in the UI, not SQL) <<<
-- Catalog > Database Explorer > REVIEWS_DB > RAW > Stages > REVIEWS_STAGE
-- > "+ Files" (top right) > pick your CSV > Upload.
-- Then check it's there:
LIST @REVIEWS_STAGE;

-- You can even query a file before loading it! $1, $2... = column 1, 2...
-- Check the columns line up with the table below before loading.
SELECT $1, $2, $3, $4, $5
FROM @REVIEWS_STAGE
LIMIT 5;

-- ---------------------------------------------------------------------
-- 1g. RAW TABLE
-- Columns match the CSV exactly, in order:
--   Time_submitted, Review, Rating, Total_thumbsup, Reply
--
-- Notice time_submitted is a STRING, not a TIMESTAMP. That's on purpose:
-- the RAW layer should accept the data exactly as it arrives, even if a
-- few dates are badly formatted. We convert it to a real timestamp in
-- Step 2 (cleaning), where a bad value becomes NULL instead of making
-- the whole load fail.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE RAW_REVIEWS (
  time_submitted   STRING,    -- e.g. '2022-07-09 15:00:00'
  review           STRING,    -- the review text
  rating           INTEGER,   -- 1 to 5 stars
  total_thumbsup   INTEGER,   -- how many people found it helpful
  reply            STRING     -- Spotify's reply (mostly empty)
);

-- ---------------------------------------------------------------------
-- 1h. COPY INTO = bulk-load files from the stage into the table
-- First a dry run: VALIDATION_MODE checks every row and returns errors
-- WITHOUT loading anything. Empty result = all good.
-- ---------------------------------------------------------------------
COPY INTO RAW_REVIEWS
FROM @REVIEWS_STAGE
VALIDATION_MODE = RETURN_ERRORS;

-- The dry run found 4 broken rows out of ~61k (lines that end too early,
-- "End of record reached while expected to parse column").
-- By default COPY INTO aborts the whole load on the first error.
-- ON_ERROR = 'CONTINUE' loads every good row and skips the bad ones.
-- That's the usual choice when a tiny fraction is broken, AS LONG AS you
-- check what was skipped (next query).
-- The result shows rows_parsed vs rows_loaded and errors_seen per file.
COPY INTO RAW_REVIEWS
FROM @REVIEWS_STAGE
ON_ERROR = 'CONTINUE';

-- VALIDATE shows the rows the last COPY INTO rejected, and why.
-- '_last' means "the most recent load job into this table".
SELECT * FROM TABLE(VALIDATE(RAW_REVIEWS, JOB_ID => '_last'));

-- ---------------------------------------------------------------------
-- 1i. Check it worked
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS total_rows FROM RAW_REVIEWS;   -- expect roughly 61,000

-- How are the star ratings spread?
SELECT rating, COUNT(*) AS n
FROM RAW_REVIEWS
GROUP BY rating
ORDER BY rating;

-- What date range do the reviews cover? (MIN/MAX work on strings too,
-- because this date format sorts correctly as text.)
SELECT MIN(time_submitted) AS first_review,
       MAX(time_submitted) AS last_review
FROM RAW_REVIEWS;

SELECT * FROM RAW_REVIEWS LIMIT 10;