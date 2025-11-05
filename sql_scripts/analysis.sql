-- ###########################################################
-- ##              BLOCK 1: CREATE MASTER VIEW                 
-- ## ------------------------------------------------------- ##
-- ##  Objective: Join all 5 core tables into a clean base
-- ##  for all future analysis.
-- ###########################################################
CREATE VIEW capstone_project_1.olist_master_view AS(
SELECT
-- 1.key ids and scores
o.order_id,
o.order_status,
r.review_score,
-- 2.fields for logistics analysis
-- these are the core fields for calculating delivery delays
o.order_purchase_timestamp,
o.order_approved_at,
o.order_delivered_customer_date,
o.order_estimated_delivery_date,
-- 3.fields for product analysis
p.product_category_name,
p.product_photos_qty,
-- 4.fields for geo/seller analysis
s.seller_state,
s.seller_city,
-- 5.other factors that may lead to bad reviews
oi.price,
oi.freight_value
FROM
capstone_project_1.orders AS o
-- use INNER JOIN for reviews,as we only want to analyze orders that have a review
INNER JOIN
capstone_project_1.order_reviews AS r ON o.order_id = r.order_id
-- use INNER JOIN for items,as we only care about orders that actually contain product
INNER JOIN
capstone_project_1.order_items AS oi ON o.order_id = oi.order_id
-- use LEFT JOIN for products,this prevents us from losing order data
LEFT JOIN
capstone_project_1.products AS p ON oi.product_id = p.product_id
-- similarly,use LEFT JOIN for sellers to ensure data robustness
LEFT JOIN
capstone_project_1.sellers AS s ON oi.seller_id = s.seller_id
WHERE
o.order_status = 'delivered'
)

-- ###########################################################
-- ##         BLOCK 2: LOGISTICS PERFORMANCE ANALYSIS         ##
-- ## ------------------------------------------------------- ##
-- ##  Objective: Analyze the impact of *actual* delivery time 
-- ##  (FROM purchase to delivery) on customer review scores.
-- ###########################################################

-- ##  ANALYST'S NOTE:
-- ##
-- ##  An initial exploratory query found that the raw 'order_estimated_delivery_date' 
-- ##  field is UNRELIABLE (e.g., estimates are 140+ days *after* actual delivery).
-- ##
-- ##  PIVOT: We are therefore using a new, reliable metric: 'actual_delivery_time' 
-- ##  (time from 'order_purchase_timestamp' to 'order_delivered_customer_date').
-- ##  This new metric showed a reliable distribution (Median: 10d, 90th: 23d).

WITH
-- this CTE cleans the data and calculates the actual time a customer waits
 delivery_time_calc AS (
  SELECT
  order_id,
  review_score,
  -- calculate the actual days from purchase to delivery
  DATE_DIFF(CAST(order_delivered_customer_date AS DATE),CAST(order_purchase_timestamp AS DATE),day) AS days_for_delivery
  FROM 
  capstone_project_1.olist_master_view
WHERE 
order_delivered_customer_date IS NOT NULL
AND
order_purchase_timestamp IS NOT NULL
)
-- this is where we group by the rules defined above to get our answer
SELECT
-- this case statement implements our new,data_driven business rules
CASE 
WHEN days_for_delivery <= 7 THEN 'fast(<= 7d)'
WHEN days_for_delivery > 7 AND days_for_delivery <= 15 THEN 'standard(8-15d)'
WHEN days_for_delivery >15 AND days_for_delivery <=23 THEN 'slow(16-23d)'
WHEN days_for_delivery > 23 THEN 'very slow(> 23d)'
ELSE 'other'-- safety net for any nulls
END AS delivery_status,
COUNT(order_id) AS total_orders,
AVG(review_score) AS avg_review_score
FROM delivery_time_calc
WHERE days_for_delivery IS NOT NULL -- filter out any calculation errors
GROUP BY delivery_status
ORDER BY delivery_status

-- ###########################################################
-- ##              BLOCK 3: PRODUCT CATEGORY ANALYSIS         ##
-- ## ------------------------------------------------------- ##
-- ##  Objective: Identify product categories with high
-- ##  bad review rates (1 or 2 stars).
-- ###########################################################

-- ##  ANALYST'S NOTE:
-- ##
-- ##  We must filter out categories with a low sample size (e.g., < 25 reviews)
-- ##  to separate statistically significant "Signals" (like 'moveis_escritorio')
-- ##  from misleading "Noise" (like 'seguros_e_servicos').
-- ##  We use a HAVING clause for this.

-- we clean NULL product category name here,but keep all review scores
WITH product_analysis_prep AS (
SELECT
order_id,
product_category_name,
review_score
  FROM capstone_project_1.olist_master_view
  -- a review without a product category is useless for this analysis
  WHERE product_category_name IS NOT NULL
)
-- final query: aggregate by product category
SELECT
product_category_name,
-- total reviews for this category
COUNT(*) AS total_reviews,
-- the bad review rate
AVG(
  CASE 
  WHEN review_score IN (1,2) then 1.0
 ELSE 0
  END
) AS bad_review_rate,
--total bad  reviews
SUM(CASE
WHEN review_score IN (1,2) then 1
ELSE 0
END) AS total_bad_reviews
FROM product_analysis_prep
GROUP BY
product_category_name
-- we only keep categories with a meaningful sample size
HAVING
COUNT(*) >= 25
ORDER BY
bad_review_rate DESC

-- ###########################################################
-- ##              BLOCK 4: HEATMAP ANALYSIS                  ##
-- ## ------------------------------------------------------- ##
-- ##  Objective: Find the "worst of the worst" combos by
-- ##  crossing Logistics Status with Product Category.
-- ###########################################################

-- -----------------------------------------------------------------------------------
-- ##  ANALYST'S NOTE:
-- ##
-- ##  This single query combines the logic from BLOCK 2 (Logistics)
-- ##  AND BLOCK 3 (Products) into one efficient CTE.
-- ##  The final query groups by *both* dimensions to find the
-- ##  combinations that produce the lowest average scores.
-- ##  We use HAVING >= 25 to filter for statistically stable groups.
-- -----------------------------------------------------------------------------------

WITH 
-- this *single* CTE prepares all data for both analyses
combined_analysis_prep AS (
    SELECT
      review_score,
      product_category_name,
      
      -- Calculate and Create Delivery Status (Logic from BLOCK 2)
      CASE
        WHEN DATE_DIFF(CAST(order_delivered_customer_date AS DATE), CAST(order_purchase_timestamp AS DATE), DAY) <= 7  THEN '1. Fast (<= 7d)'
        WHEN DATE_DIFF(CAST(order_delivered_customer_date AS DATE), CAST(order_purchase_timestamp AS DATE), DAY) > 7  AND DATE_DIFF(CAST(order_delivered_customer_date AS DATE), CAST(order_purchase_timestamp AS DATE), DAY) <= 15 THEN '2. Standard (8-15d)'
        WHEN DATE_DIFF(CAST(order_delivered_customer_date AS DATE), CAST(order_purchase_timestamp AS DATE), DAY) > 15 AND DATE_DIFF(CAST(order_delivered_customer_date AS DATE), CAST(order_purchase_timestamp AS DATE), DAY) <= 23 THEN '3. Slow (16-23d)'
        WHEN DATE_DIFF(CAST(order_delivered_customer_date AS DATE), CAST(order_purchase_timestamp AS DATE), DAY) > 23 THEN '4. Very_Slow (> 23d)'
        ELSE 'Other'
      END AS delivery_status
      
    FROM
 capstone_project_1.olist_master_view
    WHERE
    -- clean for *both* analyses at same time
      order_delivered_customer_date IS NOT NULL
      AND order_purchase_timestamp IS NOT NULL
      AND product_category_name IS NOT NULL
  )

-- Final Query: Group by *both* dimensions
SELECT
  delivery_status,
  product_category_name,
  COUNT(*) AS total_reviews,
  AVG(review_score) AS average_score
FROM
  combined_analysis_prep
WHERE
  delivery_status != 'Other'
GROUP BY
  delivery_status,
  product_category_name

-- Filter for statistical significance (Logic FROM BLOCK 3)
HAVING
  COUNT(*) >= 25

ORDER BY
  average_score ASC

-- #####################################################################
-- ##  BLOCK 5: PRODUCT PHOTOS ANALYSIS (Contribution Rate)
-- ## -----------------------------------------------------------------##
-- ##  Objective: Calculate each photo segment's "Bad Review Rate"
-- ##  AND its "Contribution" to all bad reviews on the site.
-- #####################################################################

-- -----------------------------------------------------------------------------------
-- ##  ANALYST'S NOTE:
-- ##
-- ##  An exploratory query grouped by *raw* product_photos_qty.
-- ##  FINDINGS: '1' photo had the highest bad_review_rate (15.8%) and
-- ##  the largest sample size (54k reviews). The rate stabilized for 2-4 photos,
-- ##  and dropped significantly at '5' or more photos.
-- ##
-- ##  BUSINESS RULES: We therefore define our segments as:
-- ##  1. '1_Photo_only' (High Risk)
-- ##  2. '2_to_4_Photos' (Medium Risk)
-- ##  3. '5_or_More_Photos' (Best Practice)
-- -----------------------------------------------------------------------------------

WITH 
-- CTE 1： calculate the *total* bad reviews on the entire site
-- this will be used for our cross join
bad_reviews_calc AS (
SELECT
-- use count(*) for site-wide total bad reviews
  COUNT(*) AS total_bad_reviews
  FROM capstone_project_1.olist_master_view
  WHERE review_score in (1,2)
),
-- CTE 2:calculate metrics *per segment*
photo_segment AS (
SELECT
-- metric 1: total reviews in this segment
COUNT(*) AS total_reviews,
-- metric 2: bad review rate *within* this segment
AVG(CASE
WHEN review_score IN (1,2) THEN 1.0
ELSE 0
END) AS bad_review_rate,
-- this case statement implements our new,data-driven business rules
CASE
WHEN product_photos_qty = 1 THEN 'only_1_photo'
WHEN product_photos_qty IN (2,3,4) THEN '2_to_4_photos'
WHEN product_photos_qty >= 5 THEN '5_or_more_photos'
ELSE 'other' -- catch nulls or 0s
END AS photo_segment,
-- metric 3: total bad reviews *in this segment*
SUM(
  CASE
  WHEN review_score IN (1,2) then 1
  ELSE 0
  END
) AS total_bad_reviews_in_segment
FROM capstone_project_1.olist_master_view
WHERE product_photos_qty IS NOT NULL
AND
review_score IS NOT NULL
GROUP BY
photo_segment
)
-- final query: join the segment data (CTE2) with the total data (CTE1)
SELECT
p.photo_segment,
p.total_reviews AS total_reviews_in_segment,
p.bad_review_rate AS bad_review_rate_in_segment,
p.total_bad_reviews_in_segment,
-- metric: calculate bad review contribution rate
p.total_bad_reviews_in_segment / b.total_bad_reviews AS bad_review_contribution_rate
FROM
photo_segment AS p
CROSS JOIN
bad_reviews_calc AS b
WHERE p.photo_segment != 'other'
ORDER BY p.photo_segment

-- #####################################################################
-- ##                 BLOCK 6: FREIGHT RATIO ANALYSIS                  ##
-- ## -----------------------------------------------------------------##
-- ##  Objective: Group orders by the scientifically-defined freight
-- ##  ratio segments and calculate their average score and bad review rate.
-- #####################################################################

-- -----------------------------------------------------------------------------------
-- ##  ANALYST'S NOTE:
-- ##
-- ##  The exploratory query revealed the distribution (p25=0.13, p75=0.39).
-- ##  We use these quantiles to create statistically balanced segments.
-- ##  This avoids "hard-coding" arbitrary thresholds like 10% or 30%.
-- -----------------------------------------------------------------------------------

WITH 
-- this CTE calculates the freight_ratio and creates the segments in one step
analysis_prep AS (
  SELECT
  review_score,
  -- this case statement implements our data_driven business rules
CASE
WHEN freight_value / NULLIF(price,0) <= 0.13 THEN 'low_ratio'
WHEN freight_value / NULLIF(price,0) > 0.13 AND freight_value / NULLIF(price,0) <= 0.39 THEN 'mid_ratio'
WHEN freight_value / NULLIF(price,0) > 0.39 THEN 'high_ratio'
ELSE 'other'
END AS freight_segment
  FROM capstone_project_1.olist_master_view
  -- filter out nulls to ensure the calculation is meaningful
  WHERE review_score IS NOT NULL
  AND freight_value IS NOT NULL
  AND price IS NOT NULL
)
-- final query: group by the segments created in the CTE
SELECT
freight_segment,
COUNT(*) AS total_reviews,
AVG(review_score) AS average_score,
AVG(
CASE
WHEN review_score IN (1,2) then 1
ELSE 0
END
) AS bad_review_rate
FROM analysis_prep
WHERE
freight_segment != 'other'
GROUP BY
freight_segment
ORDER BY
freight_segment

-- #####################################################################
-- ##  BLOCK 7: SELLER GEOGRAPHIC ANALYSIS                            ##
-- ## -----------------------------------------------------------------##
-- ##  Objective: Identify seller states with potential service quality
-- ##  issues by analyzing average score and bad review rate.
-- #####################################################################

-- -----------------------------------------------------------------------------------
-- ##  ANALYST'S NOTE:
-- ##
-- ##  We group by seller_state to assess regional performance.
-- ##  CRITICAL: We use HAVING COUNT(*) >= 50 to filter out states with
-- ##  insufficient data, ensuring our conclusions are statistically sound.
-- -----------------------------------------------------------------------------------

-- group by state and calculate metrics
SELECT
COUNT(*) AS total_reviews,
seller_state,
AVG(CASE
WHEN review_score IN (1,2) then 1
ELSE 0
END) AS bad_review_rate,
AVG(review_score) AS average_review_score
FROM
capstone_project_1.olist_master_view
WHERE
seller_state IS NOT NULL
AND
review_score IS NOT NULL
GROUP BY
seller_state
-- filter for statistical significance
HAVING
COUNT(*) >= 50
-- sort by the lowest average score first
ORDER BY
average_review_score