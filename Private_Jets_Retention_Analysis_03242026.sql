-- AD HOC: PRIVATE JETS
-- SET TABLE NAMES
----------------------------------------------------------------------------------------------------------------------------------------------------
-- RAW TABLES
SET SD_MAPPING = 'ADHOC_CUS_FILE';

CREATE OR REPLACE TABLE identifier($sd_mapping) (CLIENTID VARCHAR, CLIENT_TYPE VARCHAR, AGE_BAND VARCHAR, GENDER VARCHAR, REGION VARCHAR, SIGNUP_MONTH DATE, FIRST_TRIP_DATE DATE, LAST_TRIP_DATE DATE, DAYS_SINCE_LAST_TRIP DOUBLE, 
LIFETIME_TRIPS DOUBLE, TRIPS_LAST_12M DOUBLE, LIFETIME_SPEND DOUBLE, SPEND_LAST_12M DOUBLE, AVG_SPEND_PER_TRIP DOUBLE, AVG_LEAD_TIME_DAYS DOUBLE, TRIPS_ONE_WAY DOUBLE, TRIPS_ROUND_TRIP DOUBLE, TRIPS_MULTI_LEG DOUBLE,
PREFERRED_AIRCRAFT_CATEGORY VARCHAR, NPS_RESPONSE DOUBLE, WEBSITE_VISITS_LAST_30D DOUBLE);


COPY INTO identifier($sd_mapping) FROM @s3_mapping_CUS_FILE_ADHOC CREDENTIALS=(aws_key_id = $key_id aws_secret_key= $secret_key) pattern= '.*[.]csv' on_error = CONTINUE;

-- ASSIGN SCORES BASED ON FIELDS AVAILABLE TO FIND OUT "CHURN RISK"  
-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE ADHOC_CUS_FILE_CHURNRISKVALUES AS
(
WITH base AS (
  SELECT
    clientid,
    client_type,
    age_band,
    gender,
    region,
    signup_month,
    first_trip_date,
    last_trip_date,
    days_since_last_trip,
    lifetime_trips,
    trips_last_12m,
    lifetime_spend,
    spend_last_12m,
    avg_spend_per_trip,
    avg_lead_time_days,
    trips_one_way,
    trips_round_trip,
    trips_multi_leg,
    preferred_aircraft_category,

    /* NPS is already DOUBLE */
    nps_response AS nps_score,

    /* If website_visits_last_30d is already numeric keep as-is; otherwise change to TRY_TO_NUMBER */
    website_visits_last_30d
  FROM IDENTIFIER($sd_mapping)
),

thresholds AS (
  SELECT
    client_type,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY days_since_last_trip) AS p75_days_since,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY days_since_last_trip) AS p90_days_since
  FROM base
  WHERE days_since_last_trip IS NOT NULL
  GROUP BY client_type
),

cadence AS (
  SELECT
    b.*,
    DATEDIFF('day', first_trip_date, last_trip_date) AS active_days,
    CASE
      WHEN lifetime_trips >= 2
       AND first_trip_date IS NOT NULL
       AND last_trip_date  IS NOT NULL
       AND last_trip_date  > first_trip_date
      THEN DATEDIFF('day', first_trip_date, last_trip_date) / NULLIF(lifetime_trips - 1, 0)
      ELSE NULL
    END AS avg_days_between_trips,

    /* NPS bucket from numeric score */
    CASE
      WHEN nps_score BETWEEN 0 AND 6 THEN 'DETRACTOR'
      WHEN nps_score BETWEEN 7 AND 8 THEN 'PASSIVE'
      WHEN nps_score BETWEEN 9 AND 10 THEN 'PROMOTER'
      WHEN nps_score IS NULL THEN 'UNKNOWN'
      ELSE 'UNKNOWN'
    END AS nps_bucket
  FROM base b
),

scored AS (
  SELECT
    c.*,
    t.p75_days_since,
    t.p90_days_since,

    CASE
      WHEN c.avg_days_between_trips IS NOT NULL AND c.avg_days_between_trips > 0
      THEN c.days_since_last_trip / c.avg_days_between_trips
      ELSE NULL
    END AS inactivity_vs_cadence,

    /* risk_score now includes NPS points */
    (
      CASE
        WHEN c.avg_days_between_trips IS NOT NULL AND c.avg_days_between_trips > 0 THEN
          CASE
            WHEN (c.days_since_last_trip / c.avg_days_between_trips) >= 2.5 THEN 50
            WHEN (c.days_since_last_trip / c.avg_days_between_trips) >= 2.0 THEN 40
            WHEN (c.days_since_last_trip / c.avg_days_between_trips) >= 1.5 THEN 25
            ELSE 0
          END
        ELSE
          CASE
            WHEN c.days_since_last_trip >= t.p90_days_since THEN 40
            WHEN c.days_since_last_trip >= t.p75_days_since THEN 25
            ELSE 0
          END
      END
      +
      CASE
        WHEN COALESCE(c.trips_last_12m, 0) = 0 AND COALESCE(c.lifetime_trips, 0) > 0 THEN 20
        WHEN COALESCE(c.trips_last_12m, 0) <= 1 THEN 10
        ELSE 0
      END
      +
      CASE
        WHEN COALESCE(c.lifetime_spend,0) >= 50000 AND COALESCE(c.spend_last_12m,0) = 0 THEN 15
        WHEN COALESCE(c.lifetime_spend,0) >= 50000 AND COALESCE(c.spend_last_12m,0) < 0.10 * COALESCE(c.lifetime_spend,0) THEN 8
        ELSE 0
      END
      +
      CASE
        WHEN COALESCE(c.website_visits_last_30d,0) >= 5 AND COALESCE(c.trips_last_12m,0) = 0 THEN 10
        WHEN COALESCE(c.website_visits_last_30d,0) >= 5 THEN 5
        ELSE 0
      END
      +
      /* NPS contribution */
      CASE
        WHEN c.nps_bucket = 'DETRACTOR' THEN 25
        WHEN c.nps_bucket = 'PASSIVE' THEN 5
        WHEN c.nps_bucket = 'PROMOTER' THEN -5
        ELSE 0
      END
    ) AS risk_score,

    /* tier (optional to incorporate NPS separately later) */
    CASE
      WHEN c.avg_days_between_trips IS NOT NULL AND c.avg_days_between_trips > 0 THEN
        CASE
          WHEN (c.days_since_last_trip / c.avg_days_between_trips) >= 2.0
               AND COALESCE(c.trips_last_12m,0) = 0 THEN 'HIGH'
          WHEN (c.days_since_last_trip / c.avg_days_between_trips) >= 2.0 THEN 'HIGH'
          WHEN (c.days_since_last_trip / c.avg_days_between_trips) >= 1.5
               OR COALESCE(c.trips_last_12m,0) = 0 THEN 'MEDIUM'
          ELSE 'LOW'
        END
      ELSE
        CASE
          WHEN c.days_since_last_trip >= t.p90_days_since AND COALESCE(c.trips_last_12m,0) = 0 THEN 'HIGH'
          WHEN c.days_since_last_trip >= t.p90_days_since THEN 'HIGH'
          WHEN c.days_since_last_trip >= t.p75_days_since OR COALESCE(c.trips_last_12m,0) = 0 THEN 'MEDIUM'
          ELSE 'LOW'
        END
    END AS churn_risk_tier

  FROM cadence c
  LEFT JOIN thresholds t
    ON c.client_type = t.client_type
)

SELECT * FROM scored
);

-- COUNTS BY CHURN RISK 
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT
  churn_risk_tier,
  COUNT(*) AS clients,
  ROUND(100 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 1) AS pct_clients,
  ROUND(AVG(risk_score), 1) AS avg_risk_score,
  ROUND(AVG(lifetime_spend), 0) AS avg_lifetime_spend,
  ROUND(SUM(lifetime_spend), 0) AS total_lifetime_spend
FROM ADHOC_CUS_FILE_CHURNRISKVALUES
GROUP BY 1
ORDER BY CASE churn_risk_tier WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END 

-- MOST AT RISK BY CLIENT TYPE
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT
  client_type,
  COUNT(*) AS clients,
  SUM(IFF(churn_risk_tier = 'HIGH', 1, 0)) AS high_risk_clients,
  ROUND(100 * high_risk_clients / NULLIF(clients, 0), 1) AS high_risk_pct,
  ROUND(AVG(risk_score), 1) AS avg_risk_score,
  ROUND(SUM(IFF(churn_risk_tier='HIGH', lifetime_spend, 0)), 0) AS high_risk_lifetime_spend,
  ROUND(SUM(lifetime_spend), 0) AS total_lifetime_spend
FROM ADHOC_CUS_FILE_CHURNRISKVALUES
GROUP BY 1
ORDER BY high_risk_pct DESC, high_risk_clients DESC;

-- MOST AT RISK BY REGION
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT
  region,
  COUNT(*) AS clients,
  SUM(IFF(churn_risk_tier = 'HIGH', 1, 0)) AS high_risk_clients,
  ROUND(100 * high_risk_clients / NULLIF(clients, 0), 1) AS high_risk_pct,
  ROUND(AVG(risk_score), 1) AS avg_risk_score
FROM ADHOC_CUS_FILE_CHURNRISKVALUES
GROUP BY 1
HAVING COUNT(*) >= 25
ORDER BY high_risk_pct DESC, clients DESC;


-- MOST AT RISK BY AIRCRAFT CATEGORY
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT
  preferred_aircraft_category,
  COUNT(*) AS clients,
  SUM(IFF(churn_risk_tier = 'HIGH', 1, 0)) AS high_risk_clients,
  ROUND(100 * high_risk_clients / NULLIF(clients, 0), 1) AS high_risk_pct,
  ROUND(AVG(risk_score), 1) AS avg_risk_score
FROM ADHOC_CUS_FILE_CHURNRISKVALUES
GROUP BY 1
HAVING COUNT(*) >= 25
ORDER BY high_risk_pct DESC, clients DESC;

-- WHERE TO FOCUS RETENTION 
-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT
  client_type,
  region,
  COUNT(*) AS clients,
  SUM(IFF(churn_risk_tier='HIGH', 1, 0)) AS high_risk_clients,
  ROUND(100 * high_risk_clients / NULLIF(clients,0), 1) AS high_risk_pct,
  ROUND(SUM(IFF(churn_risk_tier='HIGH', lifetime_spend, 0)), 0) AS high_risk_lifetime_spend,
  ROUND(AVG(IFF(churn_risk_tier='HIGH', lifetime_spend, NULL)), 0) AS avg_lifetime_spend_high_risk
FROM ADHOC_CUS_FILE_CHURNRISKVALUES
GROUP BY 1,2
HAVING high_risk_clients >= 10
ORDER BY high_risk_lifetime_spend DESC, high_risk_clients DESC;

-- REVENUE AT RISK
----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT
  churn_risk_tier,
  ROUND(SUM(spend_last_12m), 0) AS total_revenue_at_risk,
  COUNT(*) AS clients,
  ROUND(AVG(spend_last_12m), 0) AS avg_annual_spend_per_client
FROM ADHOC_CUS_FILE_CHURNRISKVALUES
GROUP BY churn_risk_tier
ORDER BY 
  CASE churn_risk_tier 
    WHEN 'HIGH' THEN 1 
    WHEN 'MEDIUM' THEN 2 
    WHEN 'LOW' THEN 3 
  END
  