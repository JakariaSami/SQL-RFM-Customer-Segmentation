CREATE TABLE customer_segments AS
WITH deduplicated_data AS (
    -- REMOVING DUPLICATE ROWS FROM FILE OVERLAP AND APPLY INITIAL FILTERS
    SELECT 
        *, 
        ROW_NUMBER() OVER (
            PARTITION BY "Invoice", "StockCode", "Quantity" 
            ORDER BY "InvoiceDate"
        ) as rn
    FROM 
        public.retail_data
    WHERE 
        "Customer ID" IS NOT NULL
        AND "Invoice" NOT LIKE 'C%'        
        AND "Quantity" > 0                 
        AND "Price" > 0
),
clean_data AS (
    -- CALCULATING LINE ITEM VALUE AND ENFORCE DEDUPLICATION (rn = 1)
    SELECT 
        "Customer ID" AS customer_id,
        "Invoice" AS invoice_no,
        "InvoiceDate"::timestamp AS invoice_date,
        ("Quantity" * "Price") AS total_price
    FROM deduplicated_data
    WHERE rn = 1 -- Only keeping the unique instance of the line item
),
rfm_calc AS (
    -- AGGREGATING TO CUSTOMER LEVEL AND CALCULATING RAW R, F, M METRICS
    SELECT 
        customer_id,
        -- Recency: Days since last purchase (PostgreSQL DATE_PART function)
        DATE_PART('day', (SELECT MAX(invoice_date) FROM clean_data) - MAX(invoice_date)) AS recency,
        
        -- Frequency: Counting unique orders
        COUNT(DISTINCT invoice_no) AS frequency,
        
        -- Monetary: Sum total lifetime spend
        SUM(total_price) AS monetary
    FROM 
        clean_data
    GROUP BY 
        customer_id
),
rfm_scores AS (
    -- APPLYING WINDOW FUNCTIONS TO ASSIGN R, F, M SCORES (1-5)
    SELECT
        customer_id,
        recency,
        frequency,
        monetary,
        
        -- R_Score: Smaller recency is better (highest score), so ORDER BY DESC
        NTILE(5) OVER (ORDER BY recency DESC) AS r_score, 
        
        -- F_Score: Higher frequency is better, so ORDER BY ASC
        NTILE(5) OVER (ORDER BY frequency ASC) AS f_score, 
        
        -- M_Score: Higher monetary is better, so ORDER BY ASC
        NTILE(5) OVER (ORDER BY monetary ASC) AS m_score 
    FROM 
        rfm_calc
)
-- COMBINING SCORES AND ASSIGNING SEGMENT NAMES
SELECT
    customer_id,
    recency,
    frequency,
    monetary,
    r_score,
    f_score,
    m_score,
    
    -- Creating the RFM-Cell string (e.g., '555')
    CAST(r_score AS VARCHAR) || CAST(f_score AS VARCHAR) || CAST(m_score AS VARCHAR) AS rfm_cell,
    
    -- Assigning a meaningful segment name based on the scores
    CASE 
        WHEN r_score = 5 AND f_score = 5 AND m_score = 5 THEN 'Champions'
        WHEN r_score IN (4, 5) AND f_score IN (4, 5) THEN 'Loyal Customers'
        WHEN r_score IN (1, 2) AND f_score IN (4, 5) THEN 'At-Risk' 
        WHEN r_score IN (4, 5) AND f_score IN (1, 2) THEN 'New Customers'
        WHEN r_score IN (1, 2) AND f_score IN (1, 2) THEN 'Lost'
        WHEN m_score = 5 THEN 'High Value Segment' 
        ELSE 'Other'
    END AS customer_segment
FROM 
    rfm_scores
ORDER BY 
    customer_segment, r_score DESC, f_score DESC;