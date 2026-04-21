# Planning Conversation — Time Series Forecasting with modeltime

> **Note to the reader:** this is the working transcript of my planning and build session with Claude. The tool we've been using all semester is tidymodels, and I'd never touched `modeltime`, `timetk`, ARIMA, or Prophet before this week. I kept the conversation in one continuous thread so I could see my thinking evolve. I cleaned up a few typos but left the course corrections, the dead ends, and the errors I pasted in there — they're the whole point. I wrote the code; Claude helped me understand it, diagnose what broke, and refine what I had.

---

### Me

I just got handed a time series final — 131 weeks of distribution-center shipment data, weekly_units as the target, plus is_peak_period, avg_temp_f, transport_cost_idx, price_index, local_unemp_rate. We have to use `modeltime`, which I've never used, build at least 3 models, compare them, and deploy the winner as a Docker API with vetiver. I want to plan this before I touch the keyboard. Start by telling me — high level — what the `modeltime` workflow actually looks like. I know tidymodels.

### Claude

Good instinct to plan first. `modeltime` is deliberately designed to feel like tidymodels — if you know `recipe` → `workflow` → `fit` → `predict`, you already know 80% of this. The added pieces are:

1. **Time-based split** instead of random. `timetk::time_series_split()` holds out the most recent `assess` window as your test set. You never randomly split a time series, because doing so means training on the future and testing on the past.
2. **Model specs** use `modeltime` engines — `arima_reg()`, `arima_boost()`, `prophet_reg()`, `exp_smoothing()`, etc. You wrap them in `workflow()` exactly like you're used to.
3. **A `modeltime_table()`** is the new object — a tibble that parks multiple fitted models side by side so you can calibrate, score, and forecast them all at once.
4. **Calibration** (`modeltime_calibrate(new_data = testing_data)`) computes out-of-sample residuals and confidence intervals on the test set. You can't skip it.
5. **Forecast** is split: `modeltime_forecast()` produces the tibble; `plot_modeltime_forecast()` draws the overlay.
6. **Refit on full data** before forecasting forward. Your calibrated model was trained on the training split; refit before going live or you're throwing away your most recent data.

That's the whole loop.

### Me

ok that makes sense. before I write anything, can you sketch the specs and fit pattern for one model so I know what the scaffolding looks like? don't dump a whole script on me, just show me the shape.

### Claude

```r
recipe_xreg <- recipe(weekly_units ~ date + is_peak_period + avg_temp_f,
                      data = training_data)

spec_arima <- arima_reg(seasonal_period = 52) %>%
  set_engine("auto_arima")

wflow_arima <- workflow() %>%
  add_recipe(recipe_xreg) %>%
  add_model(spec_arima) %>%
  fit(training_data)
```

Two small things worth calling out:

- `seasonal_period = 52` is mandatory for weekly data. If you leave it unset, modeltime's auto-detect sometimes picks 52 but sometimes picks something nonsensical like 13.
- Classical engines (`auto_arima`, `prophet`, `ets`) don't need `step_*()` preprocessing — a pure formula is enough.

### Me

ok that looks just like tidymodels. quick questions:

1. why 52 and not 52.18 (a year isn't exactly 52 weeks)?
2. can one recipe cover all three models or do I need one per engine?
3. what's the actual difference between `arima_reg` and `arima_boost`?

### Claude

1. For ARIMA, seasonal_period has to be an integer — it's the lag offset in the seasonal AR/MA terms. 52 is the right choice and auto.arima handles the drift internally. 52.18 is Prophet's thing (Prophet uses Fourier terms so fractional periods are fine), and `prophet_reg(seasonality_yearly = TRUE)` handles that for you automatically.
2. Yes, share one recipe. All three engines consume the same formula; they model it differently internally. Sharing the recipe actually makes your 3-way comparison apples-to-apples on architecture, not on preprocessing.
3. `arima_reg()` is a plain auto-ARIMA: picks (p,d,q)(P,D,Q)[period] orders from the data. `arima_boost()` fits the ARIMA for the seasonal/trend backbone, then trains XGBoost on the residuals using your regressors to learn non-linear structure the ARIMA can't express. It's the right call when you suspect interactions — "cold week that's also a peak week" kind of stuff.

### Me

so what three models would you pick for this dataset specifically?

### Claude

1. `arima_reg()` — baseline. Everyone's first line of defense on a weekly series.
2. `arima_boost()` — handles non-linear regressor effects. Worth including because you have a binary peak flag AND continuous features; the interaction could matter.
3. `prophet_reg()` — designed for exactly this kind of holiday-driven business series. Probably produces your best forward-forecast visuals even if it doesn't win on RMSE.

Recipe: `date + is_peak_period + avg_temp_f + transport_cost_idx`. Drop `price_index` and `local_unemp_rate` unless you have a strong hypothesis — slow-moving macro features overfit fast on 131 rows.

Don't bother with a deep-learning engine. With 131 rows, a TFT or N-BEATS will memorize the two February peaks.

### Me

why drop price_index and local_unemp_rate though? they're in the CSV, and it feels wrong not to use them.

### Claude

Fair pushback. Argument for dropping:

- Both features move slowly (weeks-to-months scale). Over a 24-week forward horizon you'd have to forecast them to forecast your target, which adds error.
- Every added regressor eats ~1 degree of freedom from a tight budget.
- They don't have an obvious theoretical link to weekly shipment volume that isn't already captured by the peak flag.

Argument for keeping: unemployment might be a leading indicator; price index could interact with peak periods.

Practical suggestion: fit the three candidates without them first. If something is catastrophically bad on a stretch of the test set, try adding unemployment back in. Don't let "I have it so I should use it" drive feature selection.

### Me

ok tabling them. what about split — what's reasonable for assess?

### Claude

24 weeks. Two quarters, long enough to include one of the early-February peaks in your test window (the hard part of the forecast), short enough to leave you 107 training rows. `cumulative = TRUE` so training pulls all available history.

### Me

what metrics should I look at? I see MAPE everywhere but it has weird issues with zeros and asymmetry.

### Claude

You're right to be skeptical. Modeltime hands you MAE, MAPE, SMAPE, MASE, RMSE, R² in one shot. My rec:

- **RMSE for selection.** Punishes big peak-week misses more than MAE, and those are the misses that matter.
- **MAPE for stakeholder reporting.** Unit-free, interpretable ("we're typically off by 14%").
- **The overlay plot.** Seriously — `plot_modeltime_forecast()` on the test window tells you *how* a model misses in a way no metric will.

### Me

push back — I want to use MAPE for selection, the ops folks think in percentages.

### Claude

Legit position. Two ways to satisfy both:

1. Pick on MAPE, report RMSE and MAE.
2. Pick on RMSE (because the big misses are the costly ones), report MAPE in the exec readout.

I'd lean #2 — the ops team might SAY they think in percentages, but their overtime budget thinks in absolute units. Cost structure should drive the selection metric.

### Me

ok fine, #2. RMSE for selection, MAPE for reporting.

deployment next — I did vetiver + Docker in the deployment assignment on the boats data. anything different for modeltime?

### Claude

One wrinkle. vetiver wants a fitted parsnip workflow. Because every spec gets wrapped in `workflow() %>% add_recipe() %>% add_model() %>% fit()`, you already have the right shape. `refit_tbl %>% pluck(".model", 1)` hands you back the workflow to pass into `vetiver_model()`. If you accidentally fit a bare spec, vetiver will error with something like "no method available to create a description for model." Workflows sidestep that.

### Me

and future frames — how does forecasting with external regressors work? I'm guessing `modeltime_forecast(h = "24 weeks")` alone isn't enough if Prophet wins and it's trained on xregs.

### Claude

Correct, that's exactly the gotcha. You build a `future_tbl` with `timetk::future_frame()` for the dates, then fill in every regressor column yourself:

- `is_peak_period`: seasonal-naive by ISO week. Peak in 2024's week 6 → peak in 2025's week 6.
- `avg_temp_f`: same pattern.
- `transport_cost_idx`: last-observation carried forward.

If you skip this Prophet will error out because its regressors are missing.

### Me

ok I think I have enough to start writing. I'll take a pass at the recipe, the three specs, and the split. Be ready for me to paste in broken code and ask why.

---

### Me

first pass at the recipe and the three specs. does this look right or am I missing something obvious?

```r
recipe_xreg <- recipe(
  weekly_units ~ date + is_peak_period + avg_temp_f + transport_cost_idx,
  data = training_data
)

spec_arima <- arima_reg(seasonal_period = 52) %>% set_engine("auto_arima")

spec_arima_boost <- arima_boost(seasonal_period = 52) %>%
  set_engine("auto_arima_xgboost")

spec_prophet <- prophet_reg(seasonality_yearly = TRUE) %>%
  set_engine("prophet")
```

### Claude

That's correct — those three specs are the right architecture and the shared recipe does what we talked about. Two notes before you fit:

- On `arima_boost`, you've got the defaults for XGBoost (trees, tree_depth, learn_rate, min_n). Fine for a first pass; we can tune later if you want to squeeze more out of it.
- On `prophet_reg`, same story. Default changepoint_num, changepoint_range, and prior scales. Default Prophet is surprisingly good, so this is a defensible first shot.

Wrap each spec in `workflow() %>% add_recipe(recipe_xreg) %>% add_model(spec_*)` and then `fit(training_data)`. Then build the `modeltime_table(wflow_arima, wflow_arima_boost, wflow_prophet)` and calibrate.

### Me

done. I've got the three workflows fitted, the modeltime_table built, calibrated on testing_data, and modeltime_accuracy() returns:

```
# A tibble: 3 × 9
  .model_id .model_desc                    .type    mae  mape smape   rmse   rsq
      <int> <chr>                          <chr>  <dbl> <dbl> <dbl>  <dbl> <dbl>
1         1 REGRESSION WITH ARIMA ERRORS   Test  31271. 45.4  36.8  35462. -0.35
2         2 ARIMA W/ XGBOOST ERRORS        Test  17111. 21.5  19.7  26524.  0.25
3         3 PROPHET W/ REGRESSORS          Test  16353. 21.3  19.3  24051.  0.38
```

so Prophet wins on every metric. cool. onto the forecast plot.

### Claude

Prophet winning on every metric is the clean story you want for the writeup — no "it wins here, loses there" caveats. Also worth pointing out in your README that plain ARIMA's negative R² is doing the talking: the peak-week misses are so bad the model does worse than predicting the mean. That's exactly the failure mode Prophet fixes.

---

### Me

I ran the forecast plot and it draws fine but the console spat this at me:

```
Warning message:
Removed 131 rows containing missing values or values outside the scale range (`geom_ribbon()`).
```

if we are doing recipes, can we do a step_impute or something to clean that up?

### Claude

Good instinct, but `step_impute` won't help here — and this is actually the right kind of warning to understand rather than silence.

The warning is cosmetic. `modeltime_forecast()` returns one big tibble where the first 131 rows are the *actual* historical data (no `.conf_lo` / `.conf_hi` because they aren't forecasts, so those columns are NA) and the last rows are the *forecasts* (conf_lo/hi filled in). When `geom_ribbon()` walks the rows, it notices the NAs on the historical part and warns.

Nothing missing from your CSV. No data quality issue. The plot looks correct.

Three options:

1. Ignore it. It's noise.
2. Wrap the plot call in `suppressWarnings(...)` if it bothers you.
3. Set `.conf_interval_show = FALSE` if you don't need the ribbon at all.

`step_impute_*` would only help if there were NAs in your *input* data — but your CSV is complete.

### Me

ok leaving it. can you add a line that also shows me model performance specs, especially ROC AUC?

### Claude

ROC AUC doesn't apply here — I don't want to fake a metric that's going to confuse whoever reads your writeup. ROC AUC measures a classifier's ability to separate two classes; it needs probabilities and labels. Your target (weekly units shipped) is continuous, so it's a regression problem. ROC AUC isn't defined.

What you actually want for a regression / forecasting model:

1. **Pretty accuracy table.** `table_modeltime_accuracy(.interactive = FALSE)` — renders the existing MAE/MAPE/SMAPE/RMSE/R² table as HTML.
2. **Per-model residual summary.** `modeltime_residuals()` + a `group_by(.model_id)` summarize, pulling mean/median/sd/min/max of the residuals. Mean ≠ 0 tells you the model is biased. SD tells you the spread.
3. **Prediction-interval coverage.** Does your 80% interval actually contain 80% of the held-out observations? If coverage is 50%, your PIs are overconfident.

Want me to draft those three blocks so you can drop them in after the accuracy table?

### Me

yes please.

### Claude

Written. Paste them after `accuracy_tbl %>% write_csv(...)` — the residual summary pulls from the calibration table you already built, and the coverage block uses the same `modeltime_forecast()` call pattern. The only extra dependency is a `left_join` on `testing_data` to compare each forecast point to its actual.

---

### Me

ok it all runs. but how do we know the models we picked are the best for each model type? the boosted ARIMA defaults probably aren't ideal.

### Claude

Honest answer: right now we don't. We're using default hyperparameters for XGBoost (inside `arima_boost`) and Prophet. Auto-ARIMA already does its own search (stepwise over p/d/q/P/D/Q), so that one is tuned. The other two aren't.

Do you want me to sketch a tuning block?

### Me

can we do some hyperparameter tuning for each model if possible without the risk of overfitting etc?

### Claude

Yes — with four safeguards baked in, which is the whole point of doing it carefully:

1. **Tune inside `training_data` only.** The 24-week `testing_data` holdout stays untouched. No leakage.
2. **Rolling-origin CV** (`time_series_cv`) not random k-fold. Random k-fold would train on the future.
3. **Small grids.** 10 Latin-hypercube candidates per model, not 100. Bigger grids overfit fast on 131 rows.
4. **1-SE rule for selection.** `select_by_one_std_err` picks the simplest config whose CV RMSE is within one standard error of the outright best. Classic overfitting guard — favors parsimony when candidates are statistically indistinguishable.

Structure is: mark the hyperparameters you want to tune as `tune()` in the spec, build a Latin-hypercube grid, run `tune_grid()` against rolling-origin resamples, then `select_by_one_std_err` and `finalize_workflow` before your final fit. I'll write up the block; you paste it between your current specs and the `fit(training_data)` calls.

### Me

ok it ran. took about 8 minutes. after tune_prophet I ran show_best and got this — what does this mean?

```
# A tibble: 5 × 11
  changepoint_num changepoint_range prior_scale_cha…¹ prior_scale_sea…² .metric .estimator   mean     n std_err
            <int>             <dbl>             <dbl>             <dbl> <chr>   <chr>       <dbl> <int>   <dbl>
1              18             0.72            0.018              0.72  rmse    standard   26578.     3   7689.
2              14             0.80            0.0045             0.12  rmse    standard   27012.     3   7843.
3              23             0.66            0.064              3.1   rmse    standard   27443.     3   7702.
4              11             0.85            0.0009             0.31  rmse    standard   27891.     3   7710.
5              27             0.63            0.31               8.9   rmse    standard   28105.     3   7721.
```

### Claude

That's `show_best(tune_prophet, metric = "rmse", n = 5)` — the top-5 Prophet configurations sorted by cross-validated RMSE.

Reading column by column:

- `changepoint_num`, `changepoint_range`, `prior_scale_changepoints`, `prior_scale_seasonality` — the four hyperparameters you asked to tune. Each row is one candidate config from the Latin hypercube.
- `.metric` / `.estimator` — just saying "this is RMSE, computed the standard way."
- `mean` — the CV RMSE averaged over all 3 rolling-origin folds. 26,578 units is the best.
- `n` — number of folds each config was evaluated on (3; we set `slice_limit = 3`).
- `std_err` — how much that mean would jump around if we resampled. ~7,700 is large. Not ideal but expected on a 131-row series.

The practical takeaway: all 5 configs are within ~1,500 units of each other on the mean, but the standard errors are ~7,700. That means **you can't statistically distinguish them.** Any one of those top-5 configs would forecast about equally well on the held-out test set.

This is exactly why the 1-SE rule matters. Instead of picking config #1 and pretending it's the best, `select_by_one_std_err` picks the simplest config (fewest changepoints, lowest prior scales) whose mean is within 1 SE of the outright best. Way less likely to be a lucky draw.

### Me

ok that makes sense. one more thing — can you add a set seed line where applicable, to make it a little bit more random?

### Claude

Gentle note: `set.seed()` does the *opposite* of making things more random — it pins the RNG to a fixed starting point so you get the *same* result every rerun. That's what you actually want for a portfolio piece: reproducibility. Otherwise you risk rerunning the script, getting slightly different accuracy numbers, and having the README no longer match the output.

Add `set.seed(2026)` in six places — before every operation that touches the RNG:

1. Before the CV resamples.
2. Before each Latin-hypercube grid (the sampling is random).
3. Before each `tune_grid()` (XGBoost and Prophet both have stochastic fitting).
4. Before each final `fit(training_data)` (so the saved pinned model matches what tuning suggested).
5. Before the winning-model refit on full data (the deployed artifact).

Same seed everywhere. Run the script twice, get the same numbers. Same plots. Same forecast. If a grader clones the repo and reruns, their accuracy table will match what's in my README.

### Me

ok added. running the full script now with the seeds in. numbers match across two runs, good.

---

### Me

hit an error on the S3 upload block:

```
Error in `curl::handle_setopt()`:
! The AWS_ACCESS_KEY_ID is empty
```

I have the creds in `.Renviron` in the repo root. what's wrong?

### Claude

Two likely culprits:

1. **R reads `~/.Renviron` (your home directory), not the project-root `.Renviron`, by default.** Easiest fix: `readRenviron(".Renviron")` at the top of your session to force it, OR move the file to `~/.Renviron` and restart RStudio.
2. **Restart required.** Even after you put creds in the right file, RStudio only loads `.Renviron` at startup. Session → Restart R.

Quick sanity check: `Sys.getenv("AWS_ACCESS_KEY_ID")` should return the key, not an empty string. If it does, the board_s3 call will work.

### Me

`readRenviron(".Renviron")` + restart fixed it. upload went through, `vetiver_pin_read(s3_board, student_net_id)` pulled it back clean, and `predict()` on the pulled model gives the same numbers as the local model. deployment done.

---

**Post-build reflection (after actually running everything):**

Three things I changed while building that didn't come up in the planning phase:

1. **The future-frame regressor lookup.** Claude suggested "seasonal-naive by ISO week" at a high level, but I had to write the `group_by(iso_week) %>% summarize(...)` pattern myself and realized the week-52/53 edge case matters if my forecast horizon crosses a year boundary. Added a `coalesce()` safeguard so any missing ISO week falls back to the series mean.
2. **The recipe-sharing decision.** I briefly considered building two recipes (with/without xregs) to compare "with vs. without regressors" for ARIMA specifically. Decided against it mid-build because it made the model-selection story fuzzier — it became a 5-way comparison where I wasn't sure if I was judging architecture or feature set. Going back to the 3-way comparison with a single recipe was the right call.
3. **The ROC AUC detour.** I asked for it because we have been talking about "model performance metrics" in this class as a benchmark and it was the first thing that came to mind. I am glad Claude pushed back instead of faking something. Now I have actual regression diagnostics (residual summary + PI coverage) that would mean something if I had to defend this in a code review.
