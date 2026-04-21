# Planning Conversation — Time Series Forecasting with modeltime

> **Note to the reader:** this is the working transcript of my planning session with Claude before I wrote a single line of R. The tool we've been using this semester is tidymodels, and I'd never touched `modeltime`, `timetk`, ARIMA, or Prophet before this week. I kept the conversation in one continuous thread so I could see my thinking evolve. I edited for typos but left the course corrections and dead ends intact because they're the whole point.

---

### Me

I just got handed a time series final. We have 131 weeks of distribution-center shipment data — weekly_units as the target, plus is_peak_period (binary holiday flag), avg_temp_f, transport_cost_idx, price_index, local_unemp_rate. I need to use the `modeltime` package, which I've never used, to build at least 3 models, compare them, and deploy the winner as a Docker API with vetiver. I want to plan this before I touch the keyboard. Start by telling me — at a high level — what the `modeltime` workflow actually looks like. I know tidymodels inside out.

### Claude

Good instinct to plan first. `modeltime` is deliberately designed to feel like tidymodels — if you know `recipe` → `workflow` → `fit` → `predict`, you already know 80% of this. The added pieces are:

1. **Time-based split** instead of random. `timetk::time_series_split()` holds out the most recent `assess` window as your test set. You never randomly split a time series, because doing so means training on the future and testing on the past.
2. **Model specs** use `modeltime` engines — `arima_reg()`, `arima_boost()`, `prophet_reg()`, `exp_smoothing()`, etc. You wrap them in `workflow()` exactly like you're used to.
3. **A `modeltime_table()`** is the new object. It's a tibble that parks multiple fitted models side by side so you can calibrate, score, and forecast them all at once.
4. **Calibration** (`modeltime_calibrate(new_data = testing_data)`) computes out-of-sample residuals and confidence intervals on the test set. It's the thing the accuracy and forecast calls read from, and you can't skip it.
5. **Forecast** is split: `modeltime_forecast()` produces the prediction tibble; `plot_modeltime_forecast()` draws the overlay chart.
6. **Refit on full data** before forecasting forward. Your calibrated model was trained on the training split; refit before going live or you're throwing away your most recent data.

That's the whole loop. Want me to walk through a minimal example end-to-end?

### Me

Yes but don't paste a huge blob. Just the specs and the fit pattern for one model so I know what the scaffolding looks like.

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
- Classical engines (`auto_arima`, `prophet`, `ets`) don't need `step_*()` preprocessing — a pure formula is enough. Save your recipe energy for the model step.

### Me

OK that looks exactly like tidymodels. Three questions:

1. Why `seasonal_period = 52` and not 52.18 (since a year isn't exactly 52 weeks)?
2. Can one recipe be shared across all three models or do I need one per engine?
3. What's the difference between `arima_reg` and `arima_boost`?

### Claude

1. For ARIMA, seasonal_period has to be an integer — it's the lag offset in the seasonal AR/MA terms. 52 is the right choice; modeltime / auto.arima will handle the slight drift internally. 52.18 is Prophet's thing (Prophet uses Fourier terms so fractional periods are fine), and `prophet_reg(seasonality_yearly = TRUE)` handles that for you automatically.
2. Yes, share one recipe. All three classical engines consume the same formula; they just model it differently internally. Sharing the recipe is actually important — it means your 3-way comparison is apples-to-apples on architecture, not on preprocessing.
3. `arima_reg()` is a plain auto-ARIMA: it picks (p,d,q)(P,D,Q)[period] orders from the data. `arima_boost()` fits the same ARIMA for the seasonal/trend backbone, then trains XGBoost on the residuals using your regressors to learn non-linear structure the ARIMA can't express. It's the right call when you suspect interactions between the xregs — "cold week that's also a peak week" kind of stuff.

### Me

So what models should I compare for THIS dataset? I have:
- weekly_units (target)
- is_peak_period (binary)
- avg_temp_f
- transport_cost_idx
- price_index
- local_unemp_rate

### Claude

Go with three classical engines:

1. `arima_reg()` — baseline. Everyone's first line of defense on a weekly series.
2. `arima_boost()` — handles non-linear regressor effects. Worth including because you have that binary peak flag AND continuous features; the interaction could matter.
3. `prophet_reg()` — designed for exactly this type of holiday-driven business series. Will probably produce your best forward-forecast visuals even if it doesn't win on RMSE.

Recipe: include `date + is_peak_period + avg_temp_f + transport_cost_idx`. Drop `price_index` and `local_unemp_rate` unless you have a strong hypothesis — they're slow-moving macro features and a 131-row series gets overfit fast.

Don't bother with a deep-learning engine. You have 131 rows. A TFT or N-BEATS will memorize the two February peaks.

### Me

Why drop price_index and local_unemp_rate? They're in the CSV. Feels wrong not to use them.

### Claude

Fair pushback. The argument for dropping:
- Both features move slowly (weeks-to-months scale). Over a 24-week forward horizon you'd have to forecast them to forecast your target, which adds error.
- With 131 rows of training data, every added regressor eats ~1 degree of freedom from a tight budget.
- They don't have an obvious theoretical link to weekly shipment volume that isn't already captured by the peak flag.

The argument for keeping:
- Unemployment might be a leading indicator for consumer demand.
- Price index could interact with peak periods (recession holidays vs. boom holidays).

Practical suggestion: fit your three candidates WITHOUT them first. If they all do fine, leave it. If one is catastrophically bad on a specific stretch of the test set, try adding unemployment back in and see if it helps. Don't let "I have it, so I should use it" drive feature selection.

### Me

Good. Tabling that. Next — split strategy. What's reasonable for assess?

### Claude

24 weeks is the sweet spot. That's two quarters, long enough to capture one of the big early-February peaks in your test set (which is the hard part of the forecast), and short enough to leave you with 107 training weeks. Use `cumulative = TRUE` so training pulls from all available history.

```r
splits <- center_data %>%
  time_series_split(assess = "24 weeks", cumulative = TRUE)
```

Visualize with `tk_time_series_cv_plan() %>% plot_time_series_cv_plan(...)` before you model — it's a sanity check that the test window lands where you expect.

### Me

What metrics for time series? I keep seeing MAPE everywhere and I don't love it because divide-by-zero and asymmetry.

### Claude

You're right to be skeptical — MAPE has real problems. Modeltime gives you MAE, MAPE, SMAPE, MASE, RMSE, R² in one shot. My recommendation:

- **RMSE for model selection.** It punishes big peak-week misses more than MAE, and those are the misses that matter for ops planning. A model that's always off by 3k on quiet weeks but misses a peak by 50k is worse than one that's off by 5k everywhere.
- **MAPE for stakeholder reporting.** Unit-free, interpretable: "we're typically off by 14%."
- **The overlay plot.** Seriously. `plot_modeltime_forecast()` on the test window tells you HOW a model misses in a way metrics never will. A model that consistently over-forecasts quiet weeks is different from one that under-forecasts peak weeks, and the plot shows that instantly.

Don't rank on a single metric. Look at all three together.

### Me

Push back — I want to use MAPE for selection. The ops people I'd be handing this to think in percentages.

### Claude

That's a legitimate position. Two ways to satisfy both:

1. Pick on MAPE, report RMSE and MAE. Defensible if your ops team genuinely reasons in percentages, because your selection criterion is aligned with your consumer.
2. Pick on RMSE (for the reason above — the big misses are the costly ones), and *report* MAPE in the exec-facing readout. You're making the technical decision on the metric that matches the cost structure, and translating for the audience at the end.

I'd lean #2 personally because the cost of a peak-week miss really is asymmetric — the ops team might SAY they think in percentages, but their overtime budget thinks in absolute units. But #1 is defensible and I don't feel strongly.

### Me

OK #2. I'll use RMSE and report MAPE.

Next: deployment. I've done vetiver + Docker before on a boats dataset in the deployment assignment. Is modeltime different?

### Claude

One wrinkle, one non-wrinkle.

The non-wrinkle: vetiver doesn't care about modeltime specifically. It wants a fitted parsnip workflow. Because you're wrapping every spec in `workflow() %>% add_recipe() %>% add_model() %>% fit()`, you already have the right shape.

The wrinkle: `refit_tbl %>% pluck(".model", 1)` gives you back that workflow so you can pass it to `vetiver_model()`. If you accidentally fit a bare spec instead of a workflow, vetiver will error with "no method available to create a description for `model`" because it doesn't know how to describe modeltime's raw engine bridge classes. Workflows sidestep this. The skeleton already has the `pluck` line wired up — leave it alone.

### Me

Got it. What about the future frame for the forward forecast? Is that really necessary?

### Claude

Yes, and it bites a lot of people. If your winning model uses external regressors — and Prophet almost certainly will in your case — `modeltime_forecast(h = "24 weeks")` alone won't work. It'll build a future frame with only `date` and Prophet will refuse to predict because its regressors are missing.

You build a `future_tbl` with `timetk::future_frame()` for the dates, then populate every regressor column yourself:
- `is_peak_period`: seasonal-naive by ISO week. If ISO-week 6 was a peak week in 2024, it's a peak week in 2025. The holiday calendar doesn't move much.
- `avg_temp_f`: same pattern — last year's week-6 temperature is a great prior for next year's week-6.
- `transport_cost_idx`: last-observation carried forward. The index moves slowly; over 24 weeks the LOCF approximation is fine.

### Me

Good. Final question — what should I put in the spec? I want to finalize it and start building.

### Claude

Six sections:

1. **Objective.** Write it in the voice of an analyst who was asked to do this. What business question does the forecast answer? What's the cost of missing a peak week?
2. **Dataset.** Date range, target scale, column list, patterns you noticed during exploration.
3. **Modeling approach.** The three candidates and WHY each one — don't just list the engines, explain the rationale.
4. **Evaluation strategy.** Split, metrics, which metric you're selecting on and why.
5. **Deployment plan.** End-to-end sequence from `modeltime_refit` through the S3 pin.
6. **Open questions.** What are you still unsure about? This section is for YOU to come back to when you hit weird behavior mid-build.

Write it in your own voice. You can have me draft it based on this conversation, but re-read every line and make sure you agree with it — the point of the spec is that YOU understand the plan. If I wrote a sentence you wouldn't defend, rewrite it.

### Me

Draft it. I'll edit.

### Claude

[Draft omitted — it became the first version of `SPEC.md`. I rewrote the objective section in my own voice, tightened the "open questions" list (Claude had five; I cut two), and changed the metric discussion to match what I actually decided.]

### Me

One more thing I want to lock in before I start. The skeleton file has Phase 4 pre-wired with `student_net_id <- "your_net_id_here"`. What's that driving?

### Claude

That single variable drives three things: the `model_name` on the `vetiver_model`, the pin name on both the local `board_folder` and the S3 `board_s3`, and the folder the grader's script pulls from inside `s3://is555-model-submissions-w26/submissions/`. Set it to your Net ID in lowercase — mine would be something like `jsmith42`. Miss that and your S3 upload lands in the wrong folder and the grader never sees it.

### Me

Fine. I'm going to start building. Thanks.

### Claude

One last nudge: run the skeleton top-to-bottom after every TODO, even the trivial ones. Time series code fails in confusing ways, and the confusing ways are much cheaper to diagnose when you only added three new lines since the last successful run. Good luck.

---

**Post-build reflection added after the fact:**

Two things I changed while actually building that didn't come up in this planning chat:

1. **The future-frame future-regressor lookup.** Claude suggested "seasonal-naive by ISO week" generally, but I had to actually write the `group_by(iso_week) %>% summarize(...)` pattern myself and realized the week-52/53 edge case matters if my forecast horizon crosses a year boundary. Added a `coalesce()` safety net.
2. **The recipe-sharing decision.** I was going to build two recipes (one with xregs, one without) to compare "with vs. without regressors" for ARIMA specifically. Decided against it mid-build because it made the model-selection story fuzzier — it became a 5-way comparison where I wasn't sure if I was judging architecture or feature set. Going back to the 3-way comparison with a single recipe was the right call.
