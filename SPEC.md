# Project Spec — Regional Distribution Center Weekly Demand Forecast

## 1. Objective

Build a 24-week-ahead forecast of weekly units shipped from a regional distribution center and ship it as a Dockerized prediction API. The forecast is primarily consumed by operations planning — how many trucks, drivers, and temp-labor hours to budget — so the cost of under-forecasting a peak week is materially larger than the cost of mild over-forecasting a quiet week. I want a model that is accurate in aggregate AND specifically resistant to missing the early-February peak, which is the load pattern that drives the ops team's worst weekends.

## 2. Dataset

- **Source:** `data/distribution_center_weekly.csv`, 131 weekly rows.
- **Coverage:** 2022-02-04 → 2024-08-02 (roughly 2.5 years, W-FRI cadence).
- **Target:** `weekly_units`. Baseline ~55–65k units/wk, peaks up to ~200k.
- **External regressors:** `is_peak_period` (binary holiday flag — 9 weeks flagged), `avg_temp_f`, `transport_cost_idx`, `price_index`, `local_unemp_rate`.
- **Patterns noticed during exploration:**
  - Strong annual seasonality dominated by an early-February spike (holiday pre-positioning).
  - Secondary bumps in late November / late December.
  - Summer is flat and boring — the series is easy in Jun–Aug.
  - `is_peak_period` correlates with about 80% of the big spikes; the April 2022 bump is an unflagged outlier worth noting but not special-casing.
  - Temperature is strongly seasonal; `transport_cost_idx` is slow-moving and roughly linear upward.

## 3. Modeling approach

Three candidates, all classical modeltime engines, all sharing a single recipe:

```
weekly_units ~ date + is_peak_period + avg_temp_f + transport_cost_idx
```

| # | Spec | Rationale |
|---|------|-----------|
| 1 | `arima_reg(seasonal_period = 52)` + `auto_arima` engine | Establishes the classical baseline. Auto-ARIMA handles the seasonal backbone; the xregs give it a handle on peak weeks it otherwise couldn't anchor. |
| 2 | `arima_boost(seasonal_period = 52, min_n = 2, learn_rate = 0.015)` + `auto_arima_xgboost` | ARIMA for the seasonality, XGBoost for non-linear residual structure in the xregs. Good when I suspect interactions (e.g., "peak week AND cold snap together"). |
| 3 | `prophet_reg(seasonality_yearly = TRUE)` + `prophet` engine | Designed for holiday-driven business series. Handles additive regressor effects cleanly and usually produces the smoothest-looking forward forecast for stakeholder-facing charts. |

All three models are wrapped in `workflow()` objects (not bare parsnip fits) so the recipe travels with the fitted object into vetiver for deployment.

## 4. Evaluation strategy

**Split.** `time_series_split(assess = "24 weeks", cumulative = TRUE)` — holds out the final 24 weeks as the test set so I'm evaluating two full quarters of genuinely-held-out data that includes one of the big early-February peaks. No random splits, because randomly splitting a time series trains on the future and tests on the past.

**Metrics.** I'll produce the full modeltime accuracy table (MAE, MAPE, SMAPE, MASE, RMSE, R²) but weight my decision on:

- **RMSE** for model selection — it penalizes the big peak-week misses more than MAE does, and those misses are the ones that actually hurt ops.
- **MAPE** for stakeholder-facing reporting — unit-free, interpretable ("we're typically off by X%").
- **Plot.** `plot_modeltime_forecast()` overlay on the test window — the best metric in the world doesn't tell you *how* a model misses; the plot does.

**Two layers of evaluation**: internal 24-week test, then a separate 12-week hold-out scored by the professor. I won't tune aggressively against the internal test; regularized defaults generalize better than hand-picked hyperparameters on a small series like this.

## 5. Deployment plan

1. Select winning model by RMSE; refit on the full 131-week series via `modeltime_refit()`.
2. `pluck(".model", 1)` — extract the underlying workflow.
3. `vetiver_model(best_fit, model_name = "kal79")`.
4. Pin locally with `board_folder("models")`.
5. `vetiver_prepare_docker()` — generates `Dockerfile`, `plumber.R`, `vetiver_renv.lock`.
6. Swap to the provided `Dockerfile.better` (pulls from `davidwilson175/byu-is-555:latest`) for a faster build.
7. `docker build -t forecast-api . && docker run -p 8000:8000 forecast-api`.
8. Sanity-check at `http://127.0.0.1:8000/__docs__/`, then batch and single-row POST tests.
9. Pin the same vetiver_model to `board_s3("is555-model-submissions-w26", prefix = "submissions/")` using the `.Renviron` credentials scoped to my Net ID.

**Future-frame wrinkle.** Whichever model wins, if it uses external regressors I need to hand `modeltime_forecast()` a `future_tbl` that populates every regressor column — `timetk::future_frame()` by itself only gives me `date`. Strategy: seasonal-naive by ISO-week for `is_peak_period` and `avg_temp_f`; last-observation carried forward for `transport_cost_idx`.

## 6. Open questions

- **Small-data risk.** 131 rows is not a lot for auto.arima's grid search or for Prophet's trend changepoints. I'm leaning on regularization-friendly defaults and keeping an eye on whether any model memorizes the two February peaks in training rather than learning a general peak-week pattern.
- **`price_index` and `local_unemp_rate`.** I excluded both from the recipe because neither has obvious predictive power over a 24-week horizon and adding slow-moving macro features to a small series invites overfit. Worth a second look after the first pass — maybe interact them with the peak flag.
- **Forward-frame regressors.** My seasonal-naive approach for `is_peak_period` assumes the 2024–25 holiday calendar mirrors 2023–24. Mostly true, but if the ops team cares about specific holidays they could hand me the real calendar.
- **Prediction intervals.** Defaulting to 80%. The ops team probably wants 95% for capacity planning; confirm with them before the real deployment.

## 7. Deliverables

| Artifact | Path |
|---|---|
| Planning transcript | `PLANNING_CHAT.md` |
| Project spec | `SPEC.md` (this file) |
| Analysis script | `forecast_pipeline.R` |
| Portfolio README | `PORTFOLIO_README.md` |
| Forecast comparison plot | `plots/forecast_comparison.png` |
| Forward forecast plot | `plots/forward_forecast.png` |
| Accuracy table | `accuracy_table.csv` |
| Docker deployment files | `Dockerfile`, `plumber.R`, `vetiver_renv.lock` (generated by `vetiver_prepare_docker`) |
| Pinned model board | `models/` (generated by `board_folder`) |
| S3 upload | `s3://is555-model-submissions-w26/submissions/kal79/` |
