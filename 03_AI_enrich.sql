-- =====================================================================
-- STEP 3: Add AI with Snowflake Cortex AI Functions
-- AI functions are called from plain SQL, like any other function.
-- The text never leaves Snowflake.
--
-- Note: older tutorials use SNOWFLAKE.CORTEX.SENTIMENT / CLASSIFY_TEXT /
-- COMPLETE. New accounts must use the newer AI_* functions instead:
--   SNOWFLAKE.CORTEX.SENTIMENT      -> AI_SENTIMENT
--   SNOWFLAKE.CORTEX.CLASSIFY_TEXT  -> AI_CLASSIFY
--   SNOWFLAKE.CORTEX.COMPLETE       -> AI_COMPLETE
--
-- New SQL file in Workspaces, paste, run one statement at a time.
-- =====================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE REVIEWS_WH;
USE SCHEMA REVIEWS_DB.ANALYTICS;

-- ---------------------------------------------------------------------
-- 3a. TRY EACH AI FUNCTION ON A FEW ROWS FIRST
-- Always test on a handful of rows: AI functions cost credits per token
-- (roughly per word), so a mistake on 60k rows is a costly mistake.
-- ---------------------------------------------------------------------

-- AI_SENTIMENT returns an OBJECT (JSON), not a single number.
-- Look at the raw_result column first to see its shape. It should look
-- something like:  {"categories":[{"name":"overall","sentiment":"negative"}]}
--
-- Reading JSON in Snowflake:
--   :categories   -> the "categories" field
--   [0]           -> first item of a list (lists start at 0)
--   :sentiment    -> the "sentiment" field inside it
--   ::STRING      -> convert to normal text

SELECT AI_COMPLETE('mistral-large2', 'Say hello in 3 words');
SELECT AI_CLASSIFY('The ads are so annoying', ['Ads', 'Bugs', 'Price']);
SELECT AI_COMPLETE('llama3.1-8b', 'Say hello in 3 words');

SELECT review_text,
       rating,
       AI_SENTIMENT(review_text)                         AS raw_result,
       raw_result:categories[0]:sentiment::STRING        AS sentiment_label
FROM CLEAN_REVIEWS
LIMIT 10;

-- AI_CLASSIFY picks the best-fitting label from YOUR list.
-- Raw result should look something like:  {"labels":["Ads"]}
SELECT review_text,
       AI_CLASSIFY(
           review_text,
           ['Ads', 'Bugs & crashes', 'Offline & downloads', 'Podcasts',
            'Shuffle & recommendations', 'Price & Premium',
            'App design & features', 'General praise']
       )                              AS raw_result,
       raw_result:labels[0]::STRING   AS topic
FROM CLEAN_REVIEWS
LIMIT 10;

-- >>> CHECK: are sentiment_label and topic filled in (not NULL)?
-- If they're NULL but raw_result has data, the JSON shape differs from
-- what I expected. Copy one raw_result value and send it to me.

-- ---------------------------------------------------------------------
-- 3b. PICK A SAMPLE
-- 61k reviews is more than a dashboard needs, and AI functions cost
-- credits per review. 10,000 reviews gives the same picture for a
-- fraction of the cost.
--
-- ORDER BY HASH(review_id) shuffles rows in a fixed, repeatable order
-- (unlike RANDOM(), you get the same 10,000 every time you run it).
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 3c. THE ENRICHED TABLE
-- Step 2 promised: why a TABLE here and not a VIEW?
-- A view re-runs its query every time someone reads it. Here that means
-- re-running the AI on 10,000 reviews every time the dashboard loads:
-- slow and costly. A table runs the AI ONCE and stores the answers.
-- Rule of thumb: cheap logic -> view, expensive results -> table.
--
-- This takes a few minutes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ENRICHED_REVIEWS AS
WITH sample AS (
    SELECT *
    FROM CLEAN_REVIEWS
    ORDER BY HASH(review_id)
    LIMIT 10000
)
SELECT
    s.*,
    AI_SENTIMENT(review_text):categories[0]:sentiment::STRING AS sentiment_label,
    AI_CLASSIFY(
        review_text,
        ['Ads', 'Bugs & crashes', 'Offline & downloads', 'Podcasts',
         'Shuffle & recommendations', 'Price & Premium',
         'App design & features', 'General praise']
    ):labels[0]::STRING AS topic
FROM sample s;

-- AI_SENTIMENT gives labels (positive / negative / neutral / mixed),
-- but averages and charts need numbers. Map labels to a score.
-- This is cheap logic, so it's a VIEW on top of the table.
CREATE OR REPLACE VIEW ENRICHED_REVIEWS_V AS
SELECT *,
       CASE sentiment_label
           WHEN 'positive' THEN  1
           WHEN 'negative' THEN -1
           ELSE 0                      -- neutral, mixed, unknown
       END AS sentiment_score
FROM ENRICHED_REVIEWS;

-- ---------------------------------------------------------------------
-- 3d. CHECK THE AI'S WORK
-- Never trust AI output blindly. Read some yourself.
-- ---------------------------------------------------------------------
SELECT COUNT(*)               AS rows_enriched,
       COUNT(sentiment_label) AS rows_with_sentiment,
       COUNT(topic)           AS rows_with_topic
FROM ENRICHED_REVIEWS;

-- Which sentiment labels did we get, and how many of each?
SELECT sentiment_label, COUNT(*) AS reviews
FROM ENRICHED_REVIEWS
GROUP BY sentiment_label
ORDER BY reviews DESC;

-- Spot-check: read 10 and ask "would I have picked that topic?"
SELECT review_text, rating, sentiment_label, topic
FROM ENRICHED_REVIEWS
ORDER BY HASH(review_id, 'check')
LIMIT 10;

-- Does sentiment agree with stars? Score should rise from 1 to 5 stars.
SELECT rating,
       COUNT(*)                       AS reviews,
       ROUND(AVG(sentiment_score), 2) AS avg_sentiment
FROM ENRICHED_REVIEWS_V
GROUP BY rating
ORDER BY rating;

-- ---------------------------------------------------------------------
-- 3e. INSIGHTS
-- ---------------------------------------------------------------------

-- What are people talking about, and how happy are they about each?
SELECT topic,
       COUNT(*)                                          AS reviews,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (), 1) AS pct_of_reviews,
       ROUND(AVG(rating), 2)                             AS avg_rating,
       ROUND(AVG(sentiment_score), 2)                    AS avg_sentiment
FROM ENRICHED_REVIEWS_V
GROUP BY topic
ORDER BY reviews DESC;

-- Stars vs words don't match: high rating with negative text, or the
-- reverse. A star-rating dashboard would never show you these.
SELECT rating, sentiment_label, topic, review_text
FROM ENRICHED_REVIEWS
WHERE (rating >= 4 AND sentiment_label = 'negative')
   OR (rating <= 2 AND sentiment_label = 'positive')
ORDER BY thumbs_up DESC
LIMIT 20;

-- ---------------------------------------------------------------------
-- 3f. LLM SUMMARY PER TOPIC (AI_COMPLETE = ask an LLM anything)
-- For each topic, take the 25 most-upvoted negative reviews, glue them
-- together with LISTAGG, and ask an LLM to summarize the main problems.
-- Only 8 LLM calls in total, so this is cheap.
--
-- If you get "model not available" or "unknown model", swap the model
-- name for another one, e.g. 'mistral-large2', 'llama3.3-70b',
-- 'snowflake-llama-3.3-70b' or 'claude-3-5-sonnet'.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE TOPIC_SUMMARIES AS
WITH top_complaints AS (
    SELECT topic, review_text
    FROM ENRICHED_REVIEWS
    WHERE rating <= 2
    QUALIFY ROW_NUMBER() OVER (PARTITION BY topic ORDER BY thumbs_up DESC) <= 25
),
bundled AS (
    SELECT topic,
           COUNT(*) AS reviews_used,
           LISTAGG(review_text, '\n---\n') AS all_reviews
    FROM top_complaints
    GROUP BY topic
)
SELECT
    topic,
    reviews_used,
    AI_COMPLETE(
        'mistral-large2',
        'You are a product analyst. Below are negative Spotify app reviews '
        || 'about "' || topic || '", separated by ---. '
        || 'List the 3 most common specific problems as short bullet points, '
        || 'most frequent first. Be concrete. No intro sentence.\n\n'
        || all_reviews
    ) AS summary
FROM bundled;

SELECT * FROM TOPIC_SUMMARIES ORDER BY topic;
