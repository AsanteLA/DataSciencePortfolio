# ============================================================================
# Forecast Pipeline: Regional Distribution Center Weekly Demand Forecasting
# ============================================================================
#
# End-to-end pipeline for a 24-week-ahead demand forecast on a weekly
# distribution-center time series, built on the tidymodels + modeltime stack.
#
# Design choices worth calling out up front:
#   * We hold out the last 24 weeks for an internal test split, because
#     time series cannot be split randomly (doing so would train on the
#     future and test on the past).
#   * We fit THREE classical modeltime candidates that all share a single
#     recipe with three external regressors (is_peak_period, avg_temp_f,
#     transport_cost_idx). Sharing the recipe makes the comparison a fair
#     apples-to-apples test of model architecture.
#   * The winning model is refit on ALL of the data before it is used for
#     a forward forecast -- otherwise we'd be throwing away our most recent
#     24 weeks of signal.
#   * The deployable artifact is a parsnip `workflow` (not a raw modeltime
#     model_fit) because vetiver's describe() only has methods for
#     workflows. Using workflow() + add_recipe() + add_model() also means
#     preprocessing travels with the model to the Docker container.
#
# Suggested flow: work top-to-bottom, running the script incrementally as you go.
# ============================================================================

# --- Libraries --------------------------------------------------------------
# tidyverse / tidymodels are the foundation. modeltime + timetk extend the
# tidymodels framework into time series territory (splits, recipes, specs,
# and a calibration table that holds multiple candidate models side by side).
library(tidyverse)
library(tidymodels)
library(modeltime)
library(timetk)
library(lubridate)
library(vetiver)
library(pins)

setwd('/Users/asante/code/is-555-12-individual-final-AsanteLA')
# 
# Sys.getenv("AWS_ACCESS_KEY_ID")
# path.expand("~/.Renviron")
# file.exists(path.expand("~/.Renviron"))
# readLines(path.expand("~/.Renviron"))
# 
# file.exists(".Renviron")
# list.files(all.files = TRUE)
# 
# readLines(".Renviron")
# readRenviron(".Renviron")
# Sys.getenv("AWS_ACCESS_KEY_ID")

# Keep the ggplot theme consistent across every plot we save to `plots/`.
theme_set(theme_minimal(base_size = 12))

# ============================================================================
# PHASE 2: DATA PREPARATION AND EXPLORATION
# ============================================================================

# --- 2.1 Load and inspect the data -----------------------------------------
# The CSV has 131 weekly observations covering Feb 2022 through Aug 2024.
# Columns: date, weekly_units (target), is_peak_period, avg_temp_f,
# transport_cost_idx, price_index, local_unemp_rate.
center_data <- read_csv("data/distribution_center_weekly.csv",
                        show_col_types = FALSE) %>%
  # modeltime/timetk expect the date column to be a proper Date, and the
  # tibble to be sorted chronologically. Sorting also guarantees that our
  # time-based split behaves as expected.
  mutate(date = as.Date(date)) %>%
  arrange(date)

# Quick sanity check -- eyeballed during development; left in for anyone
# re-running the script for the first time.
glimpse(center_data)
summary(center_data)

cat(sprintf(
  "Date range: %s to %s  (%d weekly observations)\n",
  min(center_data$date), max(center_data$date), nrow(center_data)
))
cat(sprintf(
  "Peak/holiday weeks flagged: %d (%.1f%% of the series)\n",
  sum(center_data$is_peak_period),
  mean(center_data$is_peak_period) * 100
))


# --- 2.2 Visualize the series ----------------------------------------------
# plot_series: weekly units over the full date range, with peak weeks
# highlighted in red. Peak weeks are visually obvious in early-Feb every year
# (the big spike) -- this plot makes that story land without any narration.
plot_series <- center_data %>%
  ggplot(aes(x = date, y = weekly_units)) +
  geom_line(color = "#2b4c7e", size = 0.7) +
  geom_point(
    data = filter(center_data, is_peak_period == 1),
    color = "#d62728", size = 2.2
  ) +
  scale_y_continuous(labels = scales::label_number(scale = 1/1000, suffix = "k")) +
  labs(
    title = "Weekly Units Shipped — Regional Distribution Center",
    subtitle = "Red points mark peak / holiday weeks",
    x = NULL, y = "Units shipped per week"
  )

ggsave("plots/plot_series.png", plot_series, width = 12, height = 5.5, dpi = 160)

# timetk's seasonal diagnostic decomposes the series by week-of-year,
# month, and quarter -- useful for confirming there's a real annual
# seasonal signal (there is; the early-Feb spike drives most of it).
plot_seasonality <- center_data %>%
  plot_seasonal_diagnostics(
    date, weekly_units,
    .interactive = FALSE,
    .title = "Seasonal Diagnostics — Weekly Units"
  )
ggsave("plots/plot_seasonality.png", plot_seasonality,
       width = 12, height = 6, dpi = 160)

# ACF / PACF help us reason about AR and MA orders before letting auto_arima
# pick them automatically.
plot_acf <- center_data %>%
  plot_acf_diagnostics(
    date, weekly_units,
    .interactive = FALSE,
    .title = "ACF / PACF — Weekly Units"
  )
ggsave("plots/plot_acf.png", plot_acf, width = 12, height = 5, dpi = 160)


# ============================================================================
# PHASE 3: MODEL BUILDING WITH MODELTIME
# ============================================================================

# --- 3.1 Time-based train/test split ---------------------------------------
# time_series_split() takes the most recent `assess` window as the test set
# and gives us everything prior as the training set. cumulative = TRUE says
# "use all available history to train" (as opposed to rolling-window cross
# validation). 24 weeks ≈ two full quarters and, importantly for THIS data,
# covers one of the early-Feb peaks -- so we are actually testing the hard
# part of the forecast.
splits <- center_data %>%
  time_series_split(
    date_var   = date,
    assess     = "24 weeks",
    cumulative = TRUE
  )

training_data <- training(splits)
testing_data  <- testing(splits)

# Visualize the split so we can confirm the test window lands where we expect.
plot_cv_plan <- splits %>%
  tk_time_series_cv_plan() %>%
  plot_time_series_cv_plan(
    date, weekly_units,
    .title = "Train / Test Split",
    .interactive = FALSE
  )
ggsave("plots/plot_time_series_cv_plan.png", plot_cv_plan,
       width = 12, height = 5, dpi = 160)


# --- 3.2 Model specifications ----------------------------------------------
# Every candidate shares the same recipe. Classical modeltime engines do not
# need step_*() preprocessing -- auto.arima and Prophet both consume the raw
# formula and figure out what they need internally. What we DO need to pass
# them, though, are the three external regressors: the peak flag (binary),
# avg_temp_f (continuous), and transport_cost_idx (continuous). Without the
# peak flag in particular, auto.arima has no way to anchor the Feb spike.
recipe_prophet_xreg <- recipe(
  weekly_units ~ date + is_peak_period + avg_temp_f + transport_cost_idx,
  data = training_data
)

# Model 1: Auto-ARIMA with external regressors (the workhorse of classical
# forecasting). seasonal_period = 52 is CRITICAL for weekly data -- left
# unset, modeltime guesses and can land on a nonsensical period.
spec_arima <- arima_reg(seasonal_period = 52) %>%
  set_engine("auto_arima")

# Model 2: Boosted ARIMA. ARIMA carries the seasonal backbone, XGBoost
# models the residuals on top of the external regressors. We mark four
# XGBoost knobs as tune() here and search them in Phase 3.2b. The ARIMA
# backbone stays auto-selected.
spec_arima_boost_tune <- arima_boost(
    seasonal_period = 52,
    trees           = tune(),
    tree_depth      = tune(),
    learn_rate      = tune(),
    min_n           = tune()
  ) %>%
  set_engine("auto_arima_xgboost")

# Model 3: Prophet. Additive decomposition of trend + yearly seasonality +
# regressor effects. Mark the trend / changepoint and prior-scale
# hyperparameters as tune() -- these are the knobs that actually matter.
spec_prophet_tune <- prophet_reg(
    seasonality_yearly       = TRUE,
    changepoint_num          = tune(),
    changepoint_range        = tune(),
    prior_scale_changepoints = tune(),
    prior_scale_seasonality  = tune()
  ) %>%
  set_engine("prophet")

# --- Workflows (pre-tuning) -------------------------------------------------
# ARIMA has no tune() placeholders -- auto_arima does its own stepwise
# search internally, so we fit this one directly. For the other two we
# build workflows WITHOUT fitting; tune_grid() needs unfitted workflows.
wflow_arima <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_arima) %>%
  fit(training_data)

wflow_arima_boost_tune <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_arima_boost_tune)

wflow_prophet_tune <- workflow() %>%
  add_recipe(recipe_prophet_xreg) %>%
  add_model(spec_prophet_tune)


# --- 3.2b Hyperparameter tuning with time-series cross-validation ----------
# Four overfitting safeguards baked into this block:
#
#   1. We tune INSIDE training_data only. The 24-week testing_data window
#      from time_series_split() stays untouched -- it only shows up again
#      in Phase 3.3 as an honest held-out scorer. No leakage.
#   2. Rolling-origin CV (time_series_cv) instead of random k-fold.
#      Random k-fold would train on the future and test on the past.
#   3. Conservative grids (10 Latin-hypercube candidates per model).
#      Larger grids overfit fast on a 131-row series.
#   4. ONE-STANDARD-ERROR rule for selection. Pick the simplest config
#      whose CV RMSE is within 1 SE of the outright best -- a classic
#      overfitting guard that favors parsimony when ties exist.
#
# Heads up: this block takes roughly 5-15 minutes to run depending on your
# machine (Prophet is the slow one). Set verbose = TRUE if you want the
# progress bars to reassure you that it isn't hung.

set.seed(2026)

# Rolling-origin CV slices inside training_data.
# initial = 18 months of training history per slice
# assess  = 12 weeks of CV validation per slice
# slice_limit = 3 keeps compute honest on ~100 rows
resamples_tscv <- training_data %>%
  time_series_cv(
    date_var    = date,
    initial     = "18 months",
    assess      = "12 weeks",
    skip        = "8 weeks",
    cumulative  = TRUE,
    slice_limit = 3
  )

# Visualize the CV plan so you can confirm it looks right before tuning.
plot_tscv <- resamples_tscv %>%
  tk_time_series_cv_plan() %>%
  plot_time_series_cv_plan(date, weekly_units,
                           .title = "Rolling-origin CV plan (tuning folds)",
                           .interactive = FALSE)
ggsave("plots/plot_tuning_cv_plan.png", plot_tscv,
       width = 12, height = 5, dpi = 160)

# --- Tuning grids ---
# Latin-hypercube spreads candidates more evenly than a random grid at this
# size, and much more efficiently than a full factorial grid. Latin
# hypercube sampling is itself stochastic, so we re-seed before each grid
# to guarantee the exact same candidate set every rerun.
set.seed(2026)
grid_boost <- grid_latin_hypercube(
  trees(range      = c(10, 30)),
  tree_depth(range = c(3, 8)),
  learn_rate(range = c(-3, -1)),  # log10 scale -> 0.001 to 0.1
  min_n(range      = c(2, 10)),
  size = 10
)

set.seed(2026)
grid_prophet <- grid_latin_hypercube(
  changepoint_num(range          = c(10, 30)),
  changepoint_range(range        = c(0.6, 0.9)),
  prior_scale_changepoints(range = c(-3, 0)),    # log10 -> 0.001 to 1
  prior_scale_seasonality(range  = c(-1, 1.3)),  # log10 -> 0.1 to ~20
  size = 10
)

# --- Run the grids ---
# metric_set includes rmse (selection), mae and mape (context). save_pred
# is FALSE because we don't need the individual fold predictions.
tune_ctrl <- control_grid(save_pred = FALSE, verbose = FALSE, allow_par = TRUE)

# Seed before each tune_grid(): XGBoost fits inside the boosted-ARIMA
# engine are stochastic (column subsampling + random tie-breaks in tree
# splits), and Prophet's L-BFGS optimizer has a small stochastic
# initialization. Seeding makes both deterministic across reruns.
set.seed(2026)
tune_boost <- wflow_arima_boost_tune %>%
  tune_grid(
    resamples = resamples_tscv,
    grid      = grid_boost,
    metrics   = metric_set(rmse, mae, mape),
    control   = tune_ctrl
  )

set.seed(2026)
tune_prophet <- wflow_prophet_tune %>%
  tune_grid(
    resamples = resamples_tscv,
    grid      = grid_prophet,
    metrics   = metric_set(rmse, mae, mape),
    control   = tune_ctrl
  )

# Peek at the top of each tuning result just to sanity-check that nothing
# exploded. show_best shows the best-RMSE configs sorted ascending.
cat("\nTop 5 boosted-ARIMA configs by CV RMSE:\n")
print(show_best(tune_boost, metric = "rmse", n = 5))
cat("\nTop 5 Prophet configs by CV RMSE:\n")
print(show_best(tune_prophet, metric = "rmse", n = 5))

# --- 1-SE selection (the overfitting guard) ---
# select_by_one_std_err picks the simplest config whose CV metric is within
# one standard error of the outright best. The trailing columns tell it
# which direction "simpler" runs -- fewer trees / fewer changepoints are
# simpler, so we list those columns.
best_boost_params <- tune_boost %>%
  select_by_one_std_err(metric = "rmse", trees, tree_depth)

best_prophet_params <- tune_prophet %>%
  select_by_one_std_err(metric = "rmse", changepoint_num, prior_scale_changepoints)

cat("\nSelected boosted-ARIMA hyperparameters (1-SE rule):\n")
print(best_boost_params)
cat("\nSelected Prophet hyperparameters (1-SE rule):\n")
print(best_prophet_params)

# --- Finalize and fit the tuned workflows on FULL training_data ------------
# finalize_workflow swaps every tune() placeholder for the chosen value,
# giving us a concrete workflow we can fit once on the full training set.
# Same rationale as above: XGBoost and Prophet are both stochastic, so we
# re-seed before each final fit so the saved pinned model exactly matches
# what the tuning summary suggested.
set.seed(2026)
wflow_arima_boost <- wflow_arima_boost_tune %>%
  finalize_workflow(best_boost_params) %>%
  fit(training_data)

set.seed(2026)
wflow_prophet <- wflow_prophet_tune %>%
  finalize_workflow(best_prophet_params) %>%
  fit(training_data)


# --- 3.3 Modeltime table, calibration, accuracy ----------------------------
# modeltime_table() is how you park multiple fitted candidates side-by-side
# so that every downstream step (calibrate, accuracy, forecast) iterates
# over all of them at once.
models_tbl <- modeltime_table(
  wflow_arima,
  wflow_arima_boost,
  wflow_prophet
)

# Calibration computes out-of-sample residuals and confidence intervals on
# the test set. It is the thing the accuracy() and forecast() calls below
# read from -- you cannot skip this step.
calibration_tbl <- models_tbl %>%
  modeltime_calibrate(new_data = testing_data)

# modeltime_accuracy() reports MAE, MAPE, SMAPE, MASE, RMSE, and R² for
# every model in the calibration table. For time series we weight MAPE and
# RMSE most heavily: MAPE gives a unit-free error in the same language the
# ops team uses ("we're typically off by X%"), and RMSE punishes the big
# peak-week misses that matter most for capacity planning.
accuracy_tbl <- calibration_tbl %>%
  modeltime_accuracy()

print(accuracy_tbl)

# Persist the accuracy table so we can embed it in the portfolio README.
# NB: model names that print as "REGRESSION WITH ARIMA ERRORS" are using
# the statistical definition of "errors" = "residuals". Don't panic.
accuracy_tbl %>%
  select(.model_id, .model_desc, .type, mae, mape, smape, rmse, rsq) %>%
  write_csv("accuracy_table.csv")

# --- Extra performance diagnostics -----------------------------------------
# NOTE on ROC AUC: this is a regression / forecasting problem (continuous
# target = weekly units shipped), so classification metrics like ROC AUC,
# accuracy, and F1 do not apply. Below are the diagnostics that actually
# matter for a forecast:
#   (a) the pretty HTML accuracy table,
#   (b) residual stats per model (bias + spread),
#   (c) prediction-interval coverage (did the 80% PI actually contain
#       80% of the test observations?).

# (a) Pretty HTML render of the accuracy table -- useful in notebooks /
# R Markdown. gt_tbl is an htmlwidget, so it pops up in the Viewer pane.
accuracy_tbl %>%
  table_modeltime_accuracy(.interactive = FALSE)

# (b) Per-model residual summary. modeltime_residuals() returns the test-set
# predictions and residuals (actual - predicted) for each model. Good
# residuals are mean-zero with symmetric spread; systematic bias shows up
# as a non-zero mean.
residuals_tbl <- calibration_tbl %>%
  modeltime_residuals()

residuals_summary <- residuals_tbl %>%
  group_by(.model_id, .model_desc) %>%
  summarize(
    mean_residual   = mean(.residuals, na.rm = TRUE),   # bias
    median_residual = median(.residuals, na.rm = TRUE), # robust bias
    sd_residual     = sd(.residuals, na.rm = TRUE),     # spread
    min_residual    = min(.residuals, na.rm = TRUE),    # worst over-forecast
    max_residual    = max(.residuals, na.rm = TRUE),    # worst under-forecast
    .groups = "drop"
  )
print(residuals_summary)

# Residual diagnostic plot (time plot + ACF + histogram, per model).
# Useful for sanity-checking that residuals look like noise, not structure.
plot_residuals <- residuals_tbl %>%
  plot_modeltime_residuals(.type = "timeplot", .interactive = FALSE)
ggsave("plots/plot_residuals.png", plot_residuals,
       width = 12, height = 5, dpi = 160)

# (c) Prediction-interval coverage. If our 80% PI is well-calibrated, about
# 80% of the test observations should fall inside [conf_lo, conf_hi]. Much
# less than that = we're overconfident; much more = we're too timid.
coverage_tbl <- calibration_tbl %>%
  modeltime_forecast(
    new_data      = testing_data,
    actual_data   = center_data,
    conf_interval = 0.80
  ) %>%
  filter(.key == "prediction") %>%           # forecast rows only
  mutate(in_interval = .value >= .conf_lo &  # did actuals fall inside?
                        .value <= .conf_hi) %>%
  # Join actuals back onto the forecast rows to compute coverage correctly.
  # (.value on prediction rows is the point forecast, not the actual.)
  left_join(
    testing_data %>% select(date = date, actual = weekly_units),
    by = c(".index" = "date")
  ) %>%
  mutate(in_interval = actual >= .conf_lo & actual <= .conf_hi) %>%
  group_by(.model_id, .model_desc) %>%
  summarize(
    coverage_80pi = mean(in_interval, na.rm = TRUE),
    .groups = "drop"
  )
print(coverage_tbl)

# The forecast comparison plot: each model's test-set predictions drawn on
# top of the full actual series. This is the centerpiece of the portfolio
# write-up because it shows *how* each model fails where it does.
plot_forecast_comparison <- calibration_tbl %>%
  modeltime_forecast(
    new_data    = testing_data,
    actual_data = center_data,
    conf_interval = 0.80
  ) %>%
  plot_modeltime_forecast(
    .interactive = FALSE,
    .title       = "Forecast Comparison on 24-Week Test Set"
  )

ggsave("plots/forecast_comparison.png", plot_forecast_comparison,
       width = 12, height = 6, dpi = 160)


# --- 3.4 Pick the best model, refit, forward forecast ----------------------
# "Best" is lowest RMSE on the test set. We use RMSE (not MAPE) for
# selection because RMSE penalizes the big peak-week misses more heavily,
# and those are the misses that actually hurt the business downstream.
best_model_id <- accuracy_tbl %>%
  slice_min(rmse, n = 1) %>%
  pull(.model_id)

cat(sprintf("Best model_id by RMSE: %d\n", best_model_id))

# Refit the winning model on the FULL dataset. The calibrated model was
# trained on the first 107 weeks; now that we've chosen a winner we want
# it to see all 131 weeks before we forecast forward.
#
# Seed one last time: this fit is what gets pinned as the deployable
# artifact, so we want the same coefficients / the same forecast on every
# rerun of the script.
set.seed(2026)
refit_tbl <- calibration_tbl %>%
  filter(.model_id == best_model_id) %>%
  modeltime_refit(data = center_data)

# --- Build a future frame for the forward forecast -------------------------
# Prophet is our expected winner, and Prophet was trained with three
# external regressors (is_peak_period, avg_temp_f, transport_cost_idx).
# modeltime_forecast(h = "24 weeks") would generate a future frame with
# only `date` -- Prophet would then refuse to predict because its xregs
# are missing. We have to build the future frame ourselves.
#
# Strategy per column:
#   * is_peak_period  -> seasonal-naive: if ISO-week N was a peak week in
#                        the most recent calendar year, mark it a peak in
#                        the future too. Clean, defensible, matches reality.
#   * avg_temp_f      -> seasonal-naive by ISO week. Temperature is
#                        strongly seasonal; last year's week-N average is
#                        a great prior for this year's.
#   * transport_cost_idx -> last-observation-carried-forward. A slow-moving
#                        economic index doesn't warrant a fancy forecast
#                        over 24 weeks; the last observed value is fine.
last_year <- center_data %>%
  filter(date >= max(date) - weeks(52)) %>%
  mutate(iso_week = isoweek(date))

future_tbl <- center_data %>%
  future_frame(.date_var = date, .length_out = "24 weeks") %>%
  mutate(iso_week = isoweek(date)) %>%
  left_join(
    last_year %>%
      group_by(iso_week) %>%
      summarize(
        is_peak_period      = as.integer(round(mean(is_peak_period))),
        avg_temp_f          = mean(avg_temp_f),
        transport_cost_idx  = mean(transport_cost_idx),
        .groups = "drop"
      ),
    by = "iso_week"
  ) %>%
  # Final safety net: any ISO week we don't have last-year data for gets
  # the full-series mean. In practice this shouldn't trigger, but better
  # to have it than to explode at predict-time.
  mutate(
    is_peak_period     = coalesce(is_peak_period,     0L),
    avg_temp_f         = coalesce(avg_temp_f,         mean(center_data$avg_temp_f)),
    transport_cost_idx = coalesce(transport_cost_idx, tail(center_data$transport_cost_idx, 1))
  ) %>%
  select(date, is_peak_period, avg_temp_f, transport_cost_idx)

# Forward forecast: winning model, next 24 weeks, with 80% prediction intervals.
plot_forward_forecast <- refit_tbl %>%
  modeltime_forecast(
    new_data    = future_tbl,
    actual_data = center_data,
    conf_interval = 0.80
  ) %>%
  plot_modeltime_forecast(
    .interactive = FALSE,
    .title       = "Forward Forecast — Next 24 Weeks"
  )

ggsave("plots/forward_forecast.png", plot_forward_forecast,
       width = 12, height = 6, dpi = 160)


# ============================================================================
# PHASE 4.1: LOCAL DOCKER DEPLOYMENT
# ============================================================================
# DO NOT RESTRUCTURE THIS PHASE. The grading and submission paths depend on
# the vetiver_model being built and pinned exactly this way. The ONLY edit
# you should make is setting `student_net_id` below to your Net ID.

# Your BYU Net ID (lowercase). This single variable drives:
#   - the vetiver_model's model_name
#   - the pin name on both the local board and the class S3 board
#   - the folder name inside the class S3 bucket at grading time
student_net_id <- "kal79"

# --- Extract the best fitted workflow/model --------------------------------
# best_fit is a parsnip workflow, not a bare model_fit -- because Phase 3.2
# wraps every candidate in workflow() + add_recipe() + add_model() before
# fitting. That's the shape vetiver_model() needs: its workflow method builds
# a description from the workflow spec rather than drilling into modeltime's
# engine bridge classes (which have no vetiver S3 methods and would error).
best_fit <- refit_tbl %>%
  pluck(".model", 1)

# Create a vetiver model object. model_name is also the pin name on every
# board this model gets written to, so we set it to the student's Net ID.
deployable_model <- vetiver_model(
  best_fit,
  model_name = student_net_id
)

deployable_model

# Pin to a local board (the pin name is taken from deployable_model$model_name)
model_board <- board_folder("models")
model_board %>% vetiver_pin_write(deployable_model)

# Generate Docker deployment files -- second arg must match the local pin name
vetiver_prepare_docker(
  model_board,
  student_net_id
)

# Docker files should now be generated. To deploy for local testing:
#   1. docker build -t forecast-api .
#   2. docker run -p 8000:8000 forecast-api
#   3. Visit http://127.0.0.1:8000/__docs__/

# --- Now Test the API (run AFTER Docker container is running) --------------

# Batch prediction test
v_api <- vetiver_endpoint("http://127.0.0.1:8000/predict")
test_preds <- predict(v_api, testing_data)
test_preds

# Single observation test via httr
library(httr)
library(jsonlite)

one_week <- testing_data %>% slice(1)
one_week_json <- toJSON(one_week)

response <- POST(
  url = "http://127.0.0.1:8000/predict",
  body = one_week_json,
  content_type_json()
)

single_pred <- fromJSON(content(response, as = "text", encoding = "UTF-8")) %>%
  as_tibble()
single_pred

# ============================================================================
# PHASE 4.2: UPLOAD MODEL TO S3 FOR GRADING
# ============================================================================

path.expand("~/.Renviron")
file.exists(path.expand("~/.Renviron"))
readLines(path.expand("~/.Renviron"))

# Connect to the class S3 bucket
# (Requires AWS credentials in .Renviron -- see assignment instructions)
s3_board <- board_s3(
  bucket = "is555-model-submissions-w26",
  prefix = "submissions/"
)

# Upload to the class S3 board. vetiver_pin_write takes the pin name from
# deployable_model$model_name, which we set to student_net_id in Phase 4.1.
vetiver_pin_write(s3_board, deployable_model)

# Verify the upload by reading it back
my_model_check <- vetiver_pin_read(s3_board, student_net_id)

my_model_check

# Quick sanity check: does it predict correctly?
test_prediction <- predict(my_model_check, testing_data)

test_prediction

#additional organization:
file.copy("plots/forecast_comparison.png", "docs/assets/images/", overwrite = TRUE)
file.copy("plots/forward_forecast.png",    "docs/assets/images/", overwrite = TRUE)
file.copy("plots/plot_series.png",         "docs/assets/images/", overwrite = TRUE)
file.copy("plots/plot_seasonality.png",    "docs/assets/images/", overwrite = TRUE)
file.copy("plots/plot_time_series_cv_plan.png", "docs/assets/images/", overwrite = TRUE)
