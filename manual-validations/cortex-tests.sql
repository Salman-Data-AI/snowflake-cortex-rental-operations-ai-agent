SELECT COUNT(*) AS row_count,
       COUNT(DISTINCT file_name) AS document_count,
       MAX(chunk_token_count) AS max_tokens,
       ROUND(AVG(chunk_token_count)) AS avg_tokens
FROM RENTAL_OPS.SILVER.policy_document_chunks;

----------------------------------------------

SELECT * FROM RENTAL_OPS.SILVER.policy_document_chunks;