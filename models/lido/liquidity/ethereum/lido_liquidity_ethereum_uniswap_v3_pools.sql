{{ config(
    alias = alias('uniswap_v3_pools'),
    tags = ['dunesql'],             
    partition_by = ['time'],
    materialized = 'table',
    file_format = 'delta',
    unique_key = ['pool', 'time'],
    post_hook='{{ expose_spells(\'["ethereum"]\',
                                "project",
                                "lido_liquidity",
                                \'["ppclunghe", "gregshestakovlido"]\') }}'
    )
}}

{% set project_start_date = '2021-05-05' %} 

with dates as (
    with day_seq as (select (sequence(cast('{{ project_start_date }}' as date), current_date, interval '1' day)) as day)
select days.day
from day_seq
cross join unnest(day) as days(day)
),
  
  
  pools AS (
    SELECT
      pool AS address,
      'ethereum' AS blockchain,
      'uniswap_v3' AS project,
      cast(fee as double) / CAST(10000 AS DOUBLE) AS fee,
      token0, token1
    FROM
      {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}}
    WHERE
      token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 
      OR token1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 
  ),
  
  
pool_per_date as ( 
select dates.day, pools.*
from dates
left join pools on 1=1
),

  tokens AS (
    SELECT DISTINCT
      token AS address
    FROM
      (
        SELECT token1 AS token
        FROM {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}}
        WHERE token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 
        UNION
        SELECT token0
        FROM {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}}
        WHERE token1 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 
        UNION
        SELECT  0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 
      ) AS t
      
  ),
  
  tokens_prices_daily AS (
    SELECT DISTINCT
      DATE_TRUNC('day', minute) AS time,
      contract_address  AS token,
      decimals, 
      symbol,
      AVG(price) AS price
    FROM
      {{source('prices','usd')}}
    WHERE
      DATE_TRUNC('day', minute) >= date '{{ project_start_date }}' 
      AND DATE_TRUNC('day', minute) < current_date
      AND blockchain = 'ethereum'
      AND contract_address IN (SELECT address  FROM tokens      )
    GROUP BY 1, 2,3,4
    UNION ALL
    SELECT DISTINCT
      DATE_TRUNC('day', minute),
      contract_address  AS token,
      decimals, 
      symbol,
      LAST_VALUE(price) OVER (
        PARTITION BY
          DATE_TRUNC('day', minute),
          contract_address
        ORDER BY
          minute NULLS FIRST range BETWEEN UNBOUNDED preceding
          AND UNBOUNDED following
      ) AS price
    FROM
      {{source('prices','usd')}}
    WHERE
      DATE_TRUNC('day', minute) = current_date
      AND blockchain = 'ethereum'
      AND contract_address IN (SELECT address  FROM tokens      )
  ),
  
  tokens_prices_hourly AS (
        SELECT DISTINCT
          DATE_TRUNC('hour', minute) AS time,
          LEAD(DATE_TRUNC('hour', minute),1,DATE_TRUNC('hour', NOW() + INTERVAL '1' hour)) OVER (PARTITION BY contract_address  ORDER BY DATE_TRUNC('hour', minute) NULLS FIRST) AS next_time,
          contract_address  AS token,
          decimals, 
          symbol,
          LAST_VALUE(price) OVER (
            PARTITION BY
              DATE_TRUNC('hour', minute),
              contract_address
            ORDER BY
              minute NULLS FIRST range BETWEEN UNBOUNDED preceding
              AND UNBOUNDED following
          ) AS price
        FROM
          {{source('prices','usd')}}
        WHERE
          DATE_TRUNC('hour', minute) >= date '{{ project_start_date }}' 
          AND blockchain = 'ethereum'
          AND contract_address IN (
            SELECT
              address
            FROM
              tokens
          )
      
  ),
  
  swap_events AS (
    SELECT
      DATE_TRUNC('day', sw.evt_block_time) AS time,
      sw.contract_address AS pool,
      cr.token0,
      cr.token1,
      SUM(CAST(amount0 AS DOUBLE)) AS amount0,
      SUM(CAST(amount1 AS DOUBLE)) AS amount1
    FROM
      {{source('uniswap_v3_ethereum','Pair_evt_Swap')}} AS sw
      LEFT JOIN {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}} AS cr ON sw.contract_address = cr.pool
    WHERE DATE_TRUNC('day', sw.evt_block_time)  >= date '{{ project_start_date }}' 
       and sw.contract_address IN (
        SELECT
          address
        FROM
          pools
      )
    GROUP BY
      1,
      2,
      3,
      4
  ),
  mint_events AS (
    SELECT
      DATE_TRUNC('day', mt.evt_block_time) AS time,
      mt.contract_address AS pool,
      cr.token0,
      cr.token1,
      SUM(CAST(amount0 AS DOUBLE)) AS amount0,
      SUM(CAST(amount1 AS DOUBLE)) AS amount1
    FROM
      {{source('uniswap_v3_ethereum','Pair_evt_Mint')}} AS mt
      LEFT JOIN {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}} AS cr ON mt.contract_address = cr.pool
    WHERE DATE_TRUNC('day', mt.evt_block_time)  >= date '{{ project_start_date }}' 
      and mt.contract_address IN (
        SELECT
          address
        FROM
          pools
      )
    GROUP BY
      1,
      2,
      3,
      4
    UNION ALL
    SELECT
      d.day AS time,
      cr.pool,
      cr.token0,
      cr.token1,
      0,
      0
    FROM
      (
        SELECT DISTINCT
          day
        FROM
          dates
      ) AS d
      LEFT JOIN {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}} AS cr ON 1 = 1
    WHERE
      cr.pool IN (
        SELECT
          address
        FROM
          pools
      )
  ),
  collect_events AS (
    SELECT
      c.evt_block_time AS time,
      c.contract_address AS pool,
      cr.token0,
      cr.token1,
      (-1) * CAST(amount0 AS DOUBLE) AS amount0,
      (-1) * CAST(amount1 AS DOUBLE) AS amount1,
      c.evt_tx_hash
    FROM
      {{source('uniswap_v3_ethereum','Pair_evt_Collect')}} AS c
      LEFT JOIN {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}} AS cr ON c.contract_address = cr.pool
    WHERE DATE_TRUNC('day', c.evt_block_time)  >= date '{{ project_start_date }}' 
      and c.contract_address IN (
        SELECT
          address
        FROM
          pools
      )
  ),
  burn_events AS (
    SELECT
      DATE_TRUNC('day', bn.evt_block_time) AS time,
      bn.contract_address AS pool,
      cr.token0,
      cr.token1,
      (-1) * SUM(CAST(amount0 AS DOUBLE)) AS amount0,
      (-1) * SUM(CAST(amount1 AS DOUBLE)) AS amount1
    FROM
      {{source('uniswap_v3_ethereum','Pair_evt_Burn')}} AS bn
      LEFT JOIN {{source('uniswap_v3_ethereum','Factory_evt_PoolCreated')}} AS cr ON bn.contract_address = cr.pool
    WHERE DATE_TRUNC('day', bn.evt_block_time)  >= date '{{ project_start_date }}' 
      and bn.contract_address IN (
        SELECT
          address
        FROM
          pools
      )
      AND NOT bn.evt_tx_hash IN (
        SELECT
          evt_tx_hash
        FROM
          collect_events
      )
    GROUP BY
      1,
      2,
      3,
      4
  ),
  daily_delta_balance AS (
    select time,
      lead(time, 1, current_date + interval '1' day) over (partition by pool order by time) as next_time, 
      pool,
      token0,
      token1,
      amount0,
      amount1 from (
    SELECT
      time,
      pool,
      token0,
      token1,
      SUM(COALESCE(amount0, 0)) AS amount0,
      SUM(COALESCE(amount1, 0)) AS amount1
    FROM
      (
        SELECT
          time,
          pool,
          token0,
          token1,
          amount0,
          amount1
        FROM
          swap_events
        UNION ALL
        SELECT
          time,
          pool,
          token0,
          token1,
          amount0,
          amount1
        FROM
          mint_events
        /*UNION ALL
        SELECT
          time,
          pool,
          token0,
          token1,
          amount0,
          amount1
        FROM
          burn_events
        */UNION ALL
        SELECT
          DATE_TRUNC('day', time),
          pool,
          token0,
          token1,
          SUM(amount0),
          SUM(amount1)
        FROM
          collect_events
        GROUP BY
          1,
          2,
          3,
          4
      ) AS balance
    GROUP BY
      1,
      2,
      3,
      4
      )
  ),
  pool_liquidity AS (
    SELECT
      time,
      LEAD(time, 1, CURRENT_DATE + INTERVAL '1' day) OVER (
        ORDER BY
          time NULLS FIRST
      ) AS next_time,
      pool,
      d.token0,
      d.token1,
      SUM(amount0) OVER (
        PARTITION BY
          pool
        ORDER BY
          time NULLS FIRST
      ) AS amount0,
      SUM(amount1) OVER (
        PARTITION BY
          pool
        ORDER BY
          time NULLS FIRST
      ) AS amount1
    FROM
    pool_per_date  c
    left join  daily_delta_balance d on c.address = d.pool and c.day >= d.time and c.day < d.next_time
  ),
  
  swap_events_hourly AS (
        SELECT
          sw.evt_block_time as time,
          sw.contract_address AS pool,
          token0,
          token1,
          COALESCE(SUM(CAST(ABS(amount0) AS DOUBLE)), 0) AS amount0,
          COALESCE(SUM(CAST(ABS(amount1) AS DOUBLE)), 0) AS amount1
        FROM
          {{source('uniswap_v3_ethereum','Pair_evt_Swap')}} AS sw 
          inner join pools on sw.contract_address = pools.address
        WHERE DATE_TRUNC('day', sw.evt_block_time)  >= date '{{ project_start_date }}' 
         
        GROUP BY 1, 2, 3, 4
        
  ),
  
  
  trading_volume AS (
    SELECT
      date_trunc('day', s.time)  AS time,
      pool,
      sum(COALESCE((p.price * amount0) / CAST(POWER(10, p.decimals) AS DOUBLE),0)) AS volume
    FROM
      swap_events_hourly AS s
      LEFT JOIN tokens_prices_hourly AS p ON date_trunc('hour', s.time) >= p.time
      AND date_trunc('hour', s.time) < p.next_time
      AND s.token0 = p.token
    group by 1,2  
  ),
  
  all_metrics AS (
    SELECT
      l.pool,
      pools.blockchain,
      pools.project,
      pools.fee,
      cast(l.time as date) as time,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN l.token0
        ELSE l.token1
      END AS main_token,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN p0.symbol
        ELSE p1.symbol
      END AS main_token_symbol,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN l.token1
        ELSE l.token0
      END AS paired_token,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN p1.symbol
        ELSE p0.symbol
      END AS paired_token_symbol,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN (
          CASE
            WHEN amount0 > 0 THEN amount0 / CAST(POWER(10, p0.decimals) AS DOUBLE)
            ELSE 0
          END
        )
        ELSE (
          CASE
            WHEN amount1 > 0 THEN amount1 / CAST(POWER(10, p1.decimals) AS DOUBLE)
            ELSE 0
          END
        )
      END AS main_token_reserve,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN (
          CASE
            WHEN amount1 > 0 THEN amount1 / CAST(POWER(10, p1.decimals) AS DOUBLE)
            ELSE 0
          END
        )
        ELSE (
          CASE
            WHEN amount0 > 0 THEN amount0 / CAST(POWER(10, p0.decimals) AS DOUBLE)
            ELSE 0
          END
        )
      END AS paired_token_reserve,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN (
          CASE
            WHEN amount0 > 0 THEN (p0.price * amount0) / CAST(POWER(10, p0.decimals) AS DOUBLE)
            ELSE 0
          END
        )
        ELSE (
          CASE
            WHEN amount1 > 0 THEN (p1.price * amount1) / CAST(POWER(10, p1.decimals) AS DOUBLE)
            ELSE 0
          END
        )
      END AS main_token_usd_reserve,
      CASE
        WHEN l.token0 = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0  THEN (
          CASE
            WHEN amount1 > 0 THEN (p1.price * amount1) / CAST(POWER(10, p1.decimals) AS DOUBLE)
            ELSE 0
          END
        )
        ELSE (
          CASE
            WHEN amount0 > 0 THEN (p0.price * amount0) / CAST(POWER(10, p0.decimals) AS DOUBLE)
            ELSE 0
          END
        )
      END AS paired_token_usd_reserve,
      volume AS trading_volume
    FROM
      pool_liquidity AS l
      LEFT JOIN pools ON l.pool = pools.address
      LEFT JOIN tokens AS t0 ON l.token0 = t0.address
      LEFT JOIN tokens AS t1 ON l.token1 = t1.address
      LEFT JOIN tokens_prices_daily AS p0 ON l.time = p0.time   AND l.token0 = p0.token
      LEFT JOIN tokens_prices_daily AS p1 ON l.time = p1.time   AND l.token1 = p1.token
      LEFT JOIN trading_volume AS tv ON l.time = tv.time AND l.pool = tv.pool
  )
SELECT
  CONCAT(
    CAST(
      CONCAT(
        CAST(
          CONCAT(
            CAST(
              CONCAT(
                CAST(
                  CONCAT(
                    CAST(blockchain AS VARCHAR),
                    CAST(
                      CONCAT(CAST(' ' AS VARCHAR), CAST(project AS VARCHAR)) AS VARCHAR
                    )
                  ) AS VARCHAR
                ),
                CAST(' ' AS VARCHAR)
              ) AS VARCHAR
            ),
            CAST(
              COALESCE(paired_token_symbol, 'unknown') AS VARCHAR
            )
          ) AS VARCHAR
        ),
        CAST(':' AS VARCHAR)
      ) AS VARCHAR
    ),
    CAST(main_token_symbol AS VARCHAR),
    CAST(' ' AS VARCHAR),
    format('%,.3f',round(coalesce(fee,0),4))
  ) AS pool_name,
  *
FROM
  all_metrics
