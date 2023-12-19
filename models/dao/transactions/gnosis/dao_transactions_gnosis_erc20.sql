{{ config(
     
    alias = 'transactions_gnosis_erc20',
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'dao_creator_tool', 'dao', 'dao_wallet_address', 'tx_hash', 'tx_index', 'tx_type', 'address_interacted_with', 'value', 'asset_contract_address']
    )
}}

{% set transactions_start_date = '2020-05-24' %}

WITH 

dao_tmp as (
        SELECT 
            blockchain, 
            dao_creator_tool, 
            dao, 
            dao_wallet_address
        FROM 
        {{ ref('dao_addresses_gnosis') }}
        WHERE dao_wallet_address IS NOT NULL 
        AND dao_wallet_address NOT IN (0x)
), 

transactions as (
        SELECT 
            evt_block_time as block_time, 
            evt_tx_hash as tx_hash, 
            contract_address as token, 
            value as value, 
            "to" as dao_wallet_address, 
            'tx_in' as tx_type,
            evt_index as tx_index,
            "from" as address_interacted_with,
            CAST(NULL as array<bigint>) as trace_address
        FROM 
        {{ source('erc20_gnosis', 'evt_transfer') }}
        {% if not is_incremental() %}
        WHERE evt_block_time >= DATE '{{transactions_start_date}}'
        {% endif %}
        {% if is_incremental() %}
        WHERE evt_block_time >= date_trunc('day', now() - interval '7' Day)
        {% endif %}
        AND "to" IN (SELECT dao_wallet_address FROM dao_tmp)

        UNION ALL 

        SELECT 
            evt_block_time as block_time, 
            evt_tx_hash as tx_hash, 
            contract_address as token, 
            value as value, 
            "from" as dao_wallet_address, 
            'tx_out' as tx_type, 
            evt_index as tx_index, 
            "to" as address_interacted_with,
            CAST(NULL as array<bigint>) as trace_address
        FROM 
        {{ source('erc20_gnosis', 'evt_transfer') }}
        {% if not is_incremental() %}
        WHERE evt_block_time >=  DATE'{{transactions_start_date}}'
        {% endif %}
        {% if is_incremental() %}
        WHERE evt_block_time >= date_trunc('day', now() - interval '7' Day)
        {% endif %}
        AND "from" IN (SELECT dao_wallet_address FROM dao_tmp)
)

SELECT 
    dt.blockchain,
    dt.dao_creator_tool, 
    dt.dao, 
    dt.dao_wallet_address, 
    CAST(date_trunc('day', t.block_time) as DATE) as block_date, 
    CAST(date_trunc('month', t.block_time) as DATE) as block_month, 
    t.block_time, 
    t.tx_type,
    t.token as asset_contract_address,
    COALESCE(er.symbol, CAST(NULL as VARCHAR)) as asset,
    CAST(t.value AS double) as raw_value, 
    t.value/POW(10, COALESCE(er.decimals, 18)) as value, 
    t.value/POW(10, COALESCE(er.decimals, 18)) *  COALESCE(p.price, dp.median_price) as usd_value,
    t.tx_hash, 
    t.tx_index,
    t.address_interacted_with,
    t.trace_address
FROM 
transactions t 
INNER JOIN 
dao_tmp dt 
    ON t.dao_wallet_address = dt.dao_wallet_address
LEFT JOIN 
{{ ref('tokens_erc20') }} er
    ON t.token = er.contract_address
    AND er.blockchain = 'gnosis'
LEFT JOIN 
{{ source('prices', 'usd') }} p 
    ON p.minute = date_trunc('minute', t.block_time)
    AND p.contract_address = t.token
    AND p.blockchain = 'gnosis'
    {% if not is_incremental() %}
    AND p.minute >= DATE '{{transactions_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p.minute >= date_trunc('day', now() - interval '7' Day)
    {% endif %}
LEFT JOIN 
{{ ref('dex_prices') }} dp 
    ON dp.hour = date_trunc('hour', t.block_time)
    AND dp.contract_address = t.token 
    AND dp.blockchain = 'gnosis'
    AND dp.hour >= DATE '{{transactions_start_date}}'
    {% if is_incremental() %}
    AND dp.hour >= date_trunc('day', now() - interval '7' Day)
    {% endif %}