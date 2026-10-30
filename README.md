# New-product demand with partial pooling: cold-start forecasts on Online Retail II

**Status: complete run, with failures reported.** The primary test result is negative: at 4 weeks of history, the partial-pooling model (M4) does not beat a carry-forward forecast (M0). Several pre-declared failure criteria are triggered. The numbers below come from the CSV files in `results/`.

## 1. The question

A product with only k weeks of sales history: how accurate and how well calibrated are forecasts of its weekly units 1 to 4 weeks ahead, and how does accuracy change as k grows from 1 to 26 weeks?

Sub-questions (DESIGN.md section 1):

1. Does partial pooling (a hierarchical model that shrinks each new product toward a prior built from similar past products) beat (a) carry-forward, (b) a model using only the product's own history, and (c) one global model?
2. Does any advantage shrink to zero as k grows?
3. Are the 80% and 50% prediction intervals calibrated, and does conformal recalibration fix any miscalibration?
4. Are the answers stable under changes to the launch rule, cleaning rules and model settings?

## 2. Data

- **Source:** Online Retail II, UCI Machine Learning Repository, dataset 502. A UK-based online wholesaler of gift products, 1 December 2009 to 9 December 2011.
- **Attribution:** Chen, D. (2012). Online Retail II [Dataset]. UCI Machine Learning Repository. https://doi.org/10.24432/C5CG6D
- **License:** Creative Commons Attribution 4.0 International (CC BY 4.0), as stated on the dataset page.
- **Not committed:** the raw zip and xlsx (45.6 MB each) are in `data/raw/`, which is in `.gitignore`. `data/download.R` fetches them and checks their size and sheet names. See `DATA.md` for the checksums and the full data dictionary.

### Cleaning (DESIGN.md section 3, applied as written)

| Step | Lines |
|---|---|
| Combined table after the sheet-overlap rule | 1,044,848 |
| Product-like StockCode (5 digits, optional letters) | 1,038,856 |
| Price above 0 and date inside the window | 1,032,918 |
| Lines kept in weeks 1 to 105 | 1,015,309 |

Source: `results/A_cleaning_and_launch_counts.csv`.

Other rules: cancellations (invoices starting with C) are not demand; weeks start on Monday; the burn-in is weeks 1 to 8; a launch is the first week with at least 1 unit after burn-in; products that sold in burn-in are excluded.

**Decision for Jessie.** Rule 1 drops 34 `DCGS` codes (157 lines), some of which look like real products (for example `DCGS0058`, MISO PRETTY GUM). The design was kept as written, so these are dropped. DATA.md section 6 asks for this decision to be made by the owner before results are produced. It is still open.

### Launch cohort

| | Development (launch week 9 to 52) | Test (launch week 53 or later) |
|---|---|---|
| Launch products | 985 | 676 |
| Usable at k = 4 (4 target weeks observed) | 832 | 579 |
| Usable at k = 12 | 694 | 394 |
| Usable at k = 26 | 480 | 215 |

Source: `results/A_usable_launches_by_k.csv`. Because training rows must have their target week at or before week 52, development launches at larger k are fewer (DESIGN.md section 5, item 3).

## 3. Method, step by step

**Step 1. Weekly series.** For each launch product, weekly units are the sum of positive quantities on sales lines, from its launch week to week 105. Weeks with no sales are zero.

**Step 2. Forecast origin.** For a product launched in week L and a history length k, the origin is week L + k - 1. Only information from weeks up to the origin is used. The targets are the units in the 4 weeks after the origin.

**Step 3. Analog products (the prior).** For each product and origin, the analog set is the 40 launches (K = 40) that launched at least 4 weeks earlier than the product. That means every analog's first k + 4 weeks ended before the origin, so no analog's future is used. Similarity combines:
- cosine similarity of word vectors built from the product description (TF-IDF, with the weighting taken from burn-in descriptions only),
- the difference in log median price as of the origin,
- whether the launch was in the same calendar quarter.

Weights were fixed before any result (1, 0.5, 0.25) and were not tuned. K was chosen on development launches only (`results/C_dev_K_selection.csv`).

**Step 4. Models.** All models are scored on their predictive mean.

| Model | What it does in plain English |
|---|---|
| M0 | Forecast every future week as the last observed week's units (carry-forward). |
| M1 | Forecast the mean of the product's own k weeks. Interval width from its own variance. |
| M2 | Same mean as M1. The dispersion is estimated by maximum likelihood from the product's own weeks. For this model the point forecast is identical to M1. |
| M3 | One global negative binomial regression across all k, fitted on development targets. Inputs: log(1 + own mean), k, horizon, log price and the season of launch. |
| M4 | Partial pooling. Each product has its own level (a random intercept with spread tau). The level is estimated from the product's own weeks. The analog curve and log price also enter as fixed effects. Fitted by maximum marginal likelihood (empirical Bayes), separately for each k. |
| M5 | Analog-only: the mean units of the analog set at the same week since launch. No product data. |
| M5g | Global-average curve from development launches at the same week since launch. This is the baseline for failure criterion F2. |

**Step 5. Training rule.** Every training row has its target week at or before week 52. The test products' own information is used only as their history.

**Step 6. Test evaluation.** Pooled WAPE (sum of absolute errors divided by sum of actual units) over horizons 1 to 4. Bootstrap confidence intervals resample products (2,000 resamples). The primary contrast is M4 minus the better of M0 and M3 at k = 4.

**Step 7. Checks.** A leakage test rebuilds the features from data cut at weeks 40 and 90 and confirms they do not change (`results/C_leakage_test.csv`, all PASS). A split-conformal step recalibrates interval widths using development predictions only.

## 4. Results

### 4.1 Headline (k = 4, 579 test launches, pooled over horizons 1 to 4)

| Model | WAPE | Bias (units per row) | 80% coverage | 50% coverage |
|---|---|---|---|---|
| M0 carry-forward | **0.680** | -5.2 | 0.829 | 0.603 |
| M4 partial pooling (EB) | 0.838 | +8.8 | 0.858 | 0.601 |
| M5 analog-only | 0.964 | -4.3 | 0.892 | 0.576 |
| M5g global-average curve | 0.950 | -18.1 | 0.865 | 0.517 |
| M1 own mean | 1.175 | +38.4 | 0.729 | 0.508 |
| M2 own-series NB | 1.175 | +38.4 | 0.655 | 0.442 |
| M3 global NB | 1.271 | +55.7 | 0.959 | 0.797 |

Source: `results/B_cold_start_metrics_pooled_h1to4.csv`.

**Primary contrast (pre-registered).** M4 minus the better of M0 and M3 is **+15.8 percentage points** (WAPE 0.838 against 0.680). The product-clustered 95% bootstrap interval is **[-9.6, +66.1]**. M4 is worse than carry-forward, and the interval does not exclude zero. Source: `results/B_primary_k4_M4_vs_best_of_M0_M3.csv`.

Other contrasts at k = 4 (`results/B_secondary_contrasts_k4.csv`):
- M4 minus M1 = -33.8 points, interval [-93.0, -5.8]. Partial pooling beats the product's own mean.
- M4 minus M5 = -12.6 points, interval [-39.0, +36.9]. Not distinguishable.
- M5 minus M5g = +1.4 points, interval [-2.7, +5.6]. Analog matching is not better than the global average here.

### 4.2 Cold-start curve (pooled WAPE over horizons 1 to 4, test launches)

| k | M0 carry-forward | M3 global NB | M4 partial pooling | M5 analog-only | M5g global curve |
|---|---|---|---|---|---|
| 1 | 2.410 | 2.151 | **1.413** | 0.992 | 0.983 |
| 2 | **0.929** | 1.629 | 1.089 | 0.952 | 0.966 |
| 3 | **0.790** | 1.484 | 0.965 | 0.955 | 0.959 |
| 4 | **0.680** | 1.271 | 0.838 | 0.964 | 0.950 |
| 6 | 0.741 | 1.183 | **0.783** | 0.954 | 0.971 |
| 8 | **0.793** | 1.021 | not usable (see 5.1) | 0.963 | 0.941 |
| 12 | 0.802 | 0.907 | not usable | 0.907 | 0.921 |
| 16 | 0.988 | **0.798** | not usable | 0.961 | 0.921 |
| 20 | **0.699** | 0.723 | not usable | 0.894 | 0.902 |
| 26 | **0.650** | 0.771 | 0.695 | 0.902 | 0.988 |

Source: `results/B_cold_start_wape_curve.csv`. Bold marks the lowest WAPE in each row among the models that could be fitted. No confidence intervals were computed for k other than 4, so differences at other k are descriptive only.

At k = 1 the partial-pooling model beats carry-forward and the global model. At k = 4 it does not. The pattern is not monotone, and it is not evidence that partial pooling helps across the cold-start range.

### 4.3 Pooling diagnostics (component D)

- Between-product spread at k = 4: tau = 2.30 (log scale). A likelihood-ratio test against tau = 0 gives a statistic of 4,658 with boundary p below 0.001. The spread is clearly not zero. Source: `results/D_tau_test_by_k.csv`.
- Shrinkage at k = 4 (test products): the median share of prior spread removed by the product's own 4 weeks is 0.94. The posterior level is strongly correlated with the product's own log mean (correlation 0.81). Source: `results/D_shrinkage_summary_k4.csv`.
- The posterior level is therefore mostly driven by the product's own weeks. Analog information enters only through the fixed-effect curve, and its estimated coefficient is reported in `results/B_M4_fit_by_k.csv`.

### 4.4 Interval calibration (component E, k = 4)

| Model | Nominal | Dev coverage (raw) | Test coverage raw | Conformal scale c | Test coverage after recalibration |
|---|---|---|---|---|---|
| M4 | 80% | 0.889 | 0.858 | 1.00 | 0.858 |
| M4 | 50% | 0.679 | 0.601 | 0.67 | 0.421 |
| M0 | 80% | 0.881 | 0.829 | 0.75 | 0.744 |
| M3 | 80% | 0.972 | 0.959 | 1.00 | 0.959 |

Source: `results/E_calibration_before_after_conformal.csv`. For M4 the 80% intervals are already slightly wide on test data (coverage 0.86). Recalibration leaves them unchanged. The 50% intervals move the wrong way after recalibration on test data (0.60 to 0.42). The development predictions for M3 and M4 are in-sample, so their calibration is optimistic.

### 4.5 Robustness (component F, k = 4, time split)

| Variant | Setting | M4 WAPE | M0 WAPE | M3 WAPE | M4 minus best of M0/M3 (points) | 95% interval |
|---|---|---|---|---|---|---|
| baseline | as specified | 0.838 | 0.680 | 1.271 | +15.8 | [-9.6, +66.1] |
| burn13 | burn-in 13 weeks | 0.916 | 0.680 | 1.166 | +23.6 | [-8.6, +89.3] |
| launch5 | launch at 5 units | 0.756 | 0.680 | 1.180 | +7.6 | [-11.1, +40.5] |
| netted | returns netted | 0.612 | 0.681 | 0.897 | **-6.9** | [-11.7, -2.5] |
| uk_only | UK customers only | 0.993 | 0.701 | 1.540 | +29.2 | [-8.9, +108.2] |
| drop_top1pct | drop top 1% by dev volume | 0.835 | 0.680 | 1.261 | +15.6 | [-9.6, +65.5] |
| poisson | Poisson likelihood | 1.228 | 0.680 | 0.831 | **+54.8** | [-1.9, +176.3] |
| K10 | 10 analogs | 0.927 | 0.680 | 1.271 | +24.7 | [-8.4, +92.7] |
| K20 | 20 analogs | 0.837 | 0.680 | 1.271 | +15.8 | [-9.1, +65.2] |
| random_split (warning check only) | random product split, no time cutoff | 0.900 | 0.747 | 1.080 | +15.3 | [-14.9, +72.5] |

Source: `results/F_robustness_k4.csv`. The baseline row reproduces the headline numbers exactly, which confirms the run is repeatable.

Two variants change the answer:
- **Returns netted:** M4 is ahead of carry-forward by 6.9 points, and the interval excludes zero. The sign flips.
- **Poisson:** M3 beats M4 (the ranking changes), and the M4 gap widens to 54.8 points.

The random product split did not inflate M4. In that run, M4 is also worse than carry-forward.

### 4.6 Pre-registered failure criteria (DESIGN.md section 6)

| Criterion | Triggered? | Evidence |
|---|---|---|
| F1: M4 beats the better of M0 and M3 at k = 4 by 3+ points, interval excluding zero | **Yes** (not met) | +15.8 points, interval [-9.6, +66.1] |
| F2: analog-only M5 not better than global-average M5g at k = 4 | **Yes** | WAPE 0.964 against 0.950 |
| F3: tau indistinguishable from zero | No | LRT boundary p < 0.001 at k = 4; tau = 2.30 |
| F4: 80% interval after recalibration outside 0.72 to 0.88 (k = 4) | No | 0.858 |
| F5: sign or ranking of M4 against M0 and M3 changes in any variant | **Yes** | Changed in `netted` (sign and ranking) and `poisson` (ranking) |
| F6: fewer than 500 test launches at k = 12 | **Yes** | 394 test launches |
| F7: Bayesian convergence fails | Not applicable (Bayesian fit not run, see 6.1). The pre-registered optimiser-code check for the empirical Bayes fit passed at every k. | Code 0 at all k |
| F7b (post-hoc, see 5.1): M4 fit failed | **Yes** at k = 8, 12, 16, 20 | Log-likelihood below the nested model, tau above 10 |

Sources: `results/B_failure_criteria_F1_F3_F6_F7.csv`, `results/E_failure_criterion_F4.csv`, `results/F_failure_criterion_F5.csv`, `results/B_posthoc_M4_fit_sanity_by_k.csv`.

### 4.7 Simulation layer (component G, labelled method check, not evidence about real demand)

SIMULATION (labelled method check; synthetic products, not real demand). Three true spreads, five replicates each, 800 development and 400 test products, k = 4 (`results/sim_pooling_check_summary.csv`, `results/sim_pooling_check_by_replicate.csv`):

| True tau | Estimated tau (mean, range over 5 runs) | M4 WAPE | Own-mean WAPE | M4 minus own mean (points) |
|---|---|---|---|---|
| 0.0 | 0.05 (0.0001 to 0.10) | 0.830 | 0.908 | -7.8 |
| 0.3 | 0.29 (0.26 to 0.31) | 0.853 | 0.903 | -5.0 |
| 1.0 | 0.69 (0.67 to 0.71) | 0.831 | 0.836 | -0.6 |

What this shows: the fitting code recovers the spread reasonably, although it is low at tau = 1.0 (0.69 against 1.0). Shrinking products toward a shared level helps most when products are alike (tau near 0), and helps least when they differ a lot. DESIGN.md section 4 expected the opposite pattern in the "pooling should help" wording, so the simulation does not support that expectation. The real-data result in 4.1 is consistent with this: partial pooling beats the product's own mean (M1), but not carry-forward.

## 5. What failed

### 5.1 M4 did not fit at k = 8, 12, 16 and 20

For these four values of k the optimiser returned code 0, but the fitted random-effect spread (tau) diverged to between 3.8e7 and 1.6e9. The fitted log-likelihood was lower than the nested model with no random effect, which cannot happen at a true maximum. These fits are reported as failed (DESIGN.md section 6, F7). M4 predictions for these k are not reported, and the cold-start curve shows them as "not usable".

This was found after the test results were read. It is a post-hoc finding, and it is labelled as such. The pre-registered F7 check (optimiser code only) did not catch it. A bounded re-fit (tau capped at a small value) would probably repair it, but that would be a change made after seeing the test results. It was not done, and it is listed as the first item of future work.

The fits at k = 1 to 6 and k = 26 pass the same check. k = 4, the headline, passes.

### 5.2 Partial pooling does not beat carry-forward at the headline point

At k = 4, M4 is worse than M0 by 15.8 points, with a wide interval. The result holds in the baseline, in K = 10 and K = 20, and in the random-split warning run. It reverses in the returns-netted variant. The honest reading is that the sign is not stable across reasonable choices.

### 5.3 Global and analog-only priors do not beat the global average

M5 (analog-only) is 1.4 points worse than M5g (global average) at k = 4. F2 is triggered. Analog matching carries no measurable information on this data at k = 4.

### 5.4 Not run

- **Bayesian (cmdstanr) fit.** CmdStan is not installed. glmmTMB could not be installed (its dependencies `nloptr` and `lme4` failed to build). The empirical Bayes fit was used instead (see 6.1).
- **Known-truth benchmark on mature products.** DESIGN.md section 4 describes it, but the specification is not precise enough to run without further choices. The held-out test set is the validation used. This is stated plainly, and the benchmark is future work.

## 6. Deviations from DESIGN.md

All deviations were written as dated amendments in `DESIGN.md` section 10 before the test-set evaluation was run (commit `d3dad85`, lock recorded in `results/PROTOCOL_LOCK.txt`). The main ones:

1. **6.1 Fitting method.** M4 is maximum marginal likelihood with a random intercept (empirical Bayes), integrated on a 61-point grid. The Bayesian fit with 4 chains was not run.
2. **6.2 Analog offset.** The analog curve is a fixed covariate with an estimated coefficient, not a fixed offset of 1.
3. **6.3 IDF weights.** Descriptions were weighted using burn-in text only, so no later text enters the similarity.
4. **6.4 Fallback.** Products with no analog use the global average curve. These are the 166 development launches in weeks 9 to 12, which have no earlier launch to draw from. No test product needed the fallback.
5. **6.5 Dispersion.** M0, M5 and M5g use the dispersion from the pooled M3 regression. M1 and M2 use their own.
6. **6.6 Robustness on top-1% products.** Volume is measured in development weeks only, so test-period volume does not affect the cohort.
7. **6.7 Post-hoc labelling.** The M4 failure check in section 5.1 was added after the test results were read. It is labelled post-hoc in `src/05_cold_start_eval.R` and in `results/B_posthoc_M4_fit_sanity_by_k.csv`.

## 7. Limits

- **One retailer, two years.** This is one UK wholesaler, mostly business customers, from 2009 to 2011. The results describe this retailer and period only.
- **Sample size.** The test set has 579 products at k = 4, but only 394 at k = 12, below the 500 that DESIGN.md asks for. The k = 12 point is reported and not interpreted (F6).
- **Heavy-tailed demand.** Product means range from about 0.1 to about 1,560 units per week. WAPE is dominated by the largest products, so the bootstrap intervals are wide.
- **Seasonality.** Development launches span launch weeks 9 to 52. Test launches in December and January fall outside that range, and the season term extrapolates there.
- **Calibration in-sample.** Development predictions for M3 and M4 are in-sample, so the conformal scale is optimistic for them.
- **Product codes.** Codes are the retailer's own, and the description text is the retailer's wording.
- **Launch definition.** A "new product" here means the first sale after burn-in, not a real product launch.

## 8. Reproduce

Run from the project root, in this order (about 45 minutes on a laptop, mostly in `03`, `07` and `08`):

```
Rscript data/download.R
Rscript data/prep_raw.R
Rscript data/feasibility_check.R
Rscript src/01_clean_and_launches.R
Rscript src/02_features_analogs.R
Rscript src/03_models_baselines.R
Rscript src/04_pooling_diagnostics.R
Rscript src/05_cold_start_eval.R
Rscript src/06_calibration.R
Rscript src/07_robustness.R
Rscript src/08_simulation_check.R
Rscript src/09_figures.R
```

Packages: `readxl`, `data.table`, `MASS`, `Matrix`, `ggplot2`. The fixed seed is 20261029. Intermediate files are written to `data/interim/` (gitignored).

Figures: `figures/fig1_cold_start_wape.png` (WAPE by k; the M1 line sits under the M2 line because their point forecasts are identical, and the M4 line has gaps at k = 8 to 20) and `figures/fig2_interval_coverage.png` (80% coverage before and after recalibration).

## 9. Open items

1. Decide the DCGS rule (section 2).
2. Repair the M4 fit at k = 8 to 20 with a bounded spread, as a clearly labelled post-hoc sensitivity analysis, and report it separately.
3. Run the known-truth benchmark on mature products.
4. Run the Bayesian fit if CmdStan is installed.
5. The commit attribution line in DESIGN.md section 9 says Sonnet 5.5, while the commits use Haiku 5.5 as the session requires. Pick one and make DESIGN.md match.
6. No GitHub remote has been created. DESIGN.md section 9 says to push after results and README exist, which is now true. Creating the public repository is a separate decision for Jessie.

## 10. Repository layout

```
DESIGN.md              protocol, with dated amendments in section 10
DATA.md                data source, checksums, dictionary, cleaning counts
README.md              this file
data/download.R        fetches the zip (raw files are gitignored)
data/prep_raw.R        sheet overlap rule, summary CSVs
data/feasibility_check.R
src/00_config.R        fixed settings and robustness variants
src/lib_pipeline.R     shared functions (cleaning, analogs, models, evaluation)
src/01 ... src/09      components A to G, in order
results/              every number in this README comes from a CSV here
figures/              final figures (R, ggplot2)
```
