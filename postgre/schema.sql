-- ====-- ============================================================================
-- DATABASE SETUP
-- Note: Database creation is handled by the dashboard script
-- This script assumes we're already connected to benchmark_db database
-- ==================================================================================================================================================
-- SCHEMA FOR STANDARD POSTGRESQL
-- File: schema.sql
-- Purpose: Create database structure and tables for benchmarking
-- Based on Citus schema, but simplified for standard PostgreSQL
-- ================================================================================

-- ============================================================================
-- DATABASE SETUP
-- Note: Database creation is handled by the dashboard script  
-- This script assumes we're already connected to benchmark_db database
-- ============================================================================

-- ============================================================================
-- TABLE: companies (advertising companies)
-- Type: Reference table (non-distributed in original Citus)
-- ============================================================================
DROP TABLE IF EXISTS companies CASCADE;
CREATE TABLE companies (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    industry VARCHAR(100),
    country VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Índices para performance
CREATE INDEX idx_companies_industry ON companies(industry);
CREATE INDEX idx_companies_country ON companies(country);

COMMENT ON TABLE companies IS 'Advertising companies - reference table';

-- ============================================================================
-- TABLE: campaigns (advertising campaigns)  
-- Type: Distributed by company_id in original Citus
-- ============================================================================
DROP TABLE IF EXISTS campaigns CASCADE;
CREATE TABLE campaigns (
    id SERIAL,
    company_id INTEGER NOT NULL,
    name VARCHAR(255) NOT NULL,
    budget DECIMAL(12,2),
    status VARCHAR(20) DEFAULT 'active',
    start_date DATE,
    end_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, company_id),
    FOREIGN KEY (company_id) REFERENCES companies(id)
);

-- Indexes for performance
CREATE INDEX idx_campaigns_status ON campaigns(status);
CREATE INDEX idx_campaigns_dates ON campaigns(start_date, end_date);
CREATE INDEX idx_campaigns_company_id ON campaigns(company_id);

COMMENT ON TABLE campaigns IS 'Advertising campaigns - distributed by company_id in Citus';

-- ============================================================================
-- TABLE: ads (individual advertisements)
-- Type: Distributed by company_id in original Citus (co-located with campaigns)
-- ============================================================================
DROP TABLE IF EXISTS ads CASCADE;
CREATE TABLE ads (
    id SERIAL,
    campaign_id INTEGER NOT NULL,
    company_id INTEGER NOT NULL,
    title VARCHAR(255) NOT NULL,
    content TEXT,
    clicks INTEGER DEFAULT 0,
    impressions INTEGER DEFAULT 0,
    cost DECIMAL(10,2),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, company_id),
    FOREIGN KEY (company_id) REFERENCES companies(id)
    -- Note: FK to campaigns commented because it needs to include company_id
    -- FOREIGN KEY (campaign_id, company_id) REFERENCES campaigns(id, company_id)
);

-- Indexes for performance
CREATE INDEX idx_ads_campaign ON ads(campaign_id);
CREATE INDEX idx_ads_performance ON ads(clicks, impressions);
CREATE INDEX idx_ads_company_id ON ads(company_id);

COMMENT ON TABLE ads IS 'Individual advertisements - co-located with campaigns in Citus';

-- ============================================================================
-- TABLE: system_metrics (system metrics)
-- Type: Local in original Citus
-- ============================================================================
DROP TABLE IF EXISTS system_metrics CASCADE;
CREATE TABLE system_metrics (
    id SERIAL PRIMARY KEY,
    metric_name VARCHAR(100) NOT NULL,
    metric_value DECIMAL(15,2),
    collected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for performance
CREATE INDEX idx_metrics_name_time ON system_metrics(metric_name, collected_at);

COMMENT ON TABLE system_metrics IS 'System metrics - local table';

-- ============================================================================
-- PERFORMANCE SETTINGS (equivalent to Citus)
-- ============================================================================

-- Configure equivalent work_mem and shared_buffers
-- (Note: These settings are applied at server level)
-- ALTER SYSTEM SET work_mem = '256MB';
-- ALTER SYSTEM SET shared_buffers = '512MB';

-- ============================================================================
-- ANALYSIS VIEWS (optional)
-- ============================================================================

-- View for campaign analysis by company
CREATE OR REPLACE VIEW campaign_summary AS
SELECT 
    c.name AS company_name,
    c.industry,
    c.country,
    COUNT(camp.id) AS total_campaigns,
    AVG(camp.budget) AS avg_budget,
    SUM(camp.budget) AS total_budget
FROM companies c
LEFT JOIN campaigns camp ON c.id = camp.company_id
GROUP BY c.id, c.name, c.industry, c.country
ORDER BY total_budget DESC;

-- View for ads performance
CREATE OR REPLACE VIEW ads_performance AS
SELECT 
    comp.name AS company_name,
    camp.name AS campaign_name,
    COUNT(a.id) AS total_ads,
    SUM(a.impressions) AS total_impressions,
    SUM(a.clicks) AS total_clicks,
    CASE 
        WHEN SUM(a.impressions) > 0 
        THEN ROUND((SUM(a.clicks)::DECIMAL / SUM(a.impressions)) * 100, 2)
        ELSE 0 
    END AS ctr_percentage,
    SUM(a.cost) AS total_cost
FROM companies comp
JOIN campaigns camp ON comp.id = camp.company_id
JOIN ads a ON camp.id = a.campaign_id AND comp.id = a.company_id
GROUP BY comp.id, comp.name, camp.id, camp.name
ORDER BY total_cost DESC;

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- Function to clean all tables
CREATE OR REPLACE FUNCTION truncate_all_tables() RETURNS void AS $$
BEGIN
    TRUNCATE TABLE ads, campaigns, companies, system_metrics RESTART IDENTITY CASCADE;
    RAISE NOTICE 'All tables have been cleaned successfully.';
END;
$$ LANGUAGE plpgsql;

-- Function to count records in all tables
CREATE OR REPLACE FUNCTION count_all_tables() RETURNS TABLE(table_name text, record_count bigint) AS $$
BEGIN
    RETURN QUERY
    SELECT 'companies'::text, COUNT(*)::bigint FROM companies
    UNION ALL
    SELECT 'campaigns'::text, COUNT(*)::bigint FROM campaigns  
    UNION ALL
    SELECT 'ads'::text, COUNT(*)::bigint FROM ads
    UNION ALL
    SELECT 'system_metrics'::text, COUNT(*)::bigint FROM system_metrics
    ORDER BY table_name;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- GRANTS AND PERMISSIONS
-- ============================================================================

-- Ensure postgres user has all permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO postgres;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO postgres;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO postgres;

-- ============================================================================
-- FINAL INFORMATION
-- ============================================================================

\echo ''
\echo '======================================================================'
\echo 'SCHEMA CREATED SUCCESSFULLY!'
\echo '======================================================================'
\echo ''
\echo 'Database: benchmark_db'
\echo 'Tables created:'
\echo '  • companies (advertising companies)'
\echo '  • campaigns (advertising campaigns)' 
\echo '  • ads (individual advertisements)'
\echo '  • system_metrics (system metrics)'
\echo ''
\echo 'Available views:'
\echo '  • campaign_summary (summary by company)'
\echo '  • ads_performance (ads performance)'
\echo ''
\echo 'Utility functions:'
\echo '  • truncate_all_tables() - cleans all tables'
\echo '  • count_all_tables() - counts records in all tables'
\echo ''
\echo 'Next step: Run the data loader to load CSV data'
\echo '======================================================================'