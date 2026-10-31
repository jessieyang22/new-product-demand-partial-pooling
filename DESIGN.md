# DESIGN: new-product-demand-partial-pooling

Status: design only, written 2026-10-29. No results exist yet. The evaluation protocol in section 5 must be committed and locked before any test-set number is produced.

## 1. Research question

When a product has only k weeks of sales history, how accurate and how well calibrated are forecasts of its weekly units for the next 1 to 4 weeks, and how does that accuracy change as k grows from 1 to 26 weeks?

Sub-questions:

1. Does partial pooling (a hierarchical model that shrinks each new product toward a prior built from similar past products, called "analog products") beat (a) a naive carry-forward forecast, (b) a per-product model that uses only that product's own history, and (c) one global model with no product-level terms?
2. Does the advantage, if any, shrink to zero as k grows (the "cold-start curve")?
3. Are the 80% and 50% prediction intervals calibrated, and does a conformal recalibration step fix any miscalibration without hurting sharpness?
4. Are the answers stable under reasonable changes to the launch definition, cleaning rules and model settings?

A null or negative answer to any sub-question is an acceptable result and will be reported as such.

## 2. Dataset

Primary dataset: Online Retail II (UCI Machine Learning Repository, dataset 502).

- Dataset page: https://archive.ics.uci.edu/dataset/502/online+retail+ii
- Direct file: https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip
- License: Creative Commons Attribution 4.0 International (CC BY 4.0). The dataset page states this license. Reuse is allowed with attribution. Attribution goes in the README.
- Content: one transactional xlsx file, `online_retail_II.xlsx`, with two sheets, `Year 2009-2010` and `Year 2010-2011`. Columns include Invoice, StockCode, Description, Quantity, InvoiceDate, Price, Customer ID and Country. The dataset page describes the coverage as 1 December 2009 to 9 December 2011, from a UK-based online wholesaler of gift products. The download script will confirm this date range.

Verified on 2026-10-29 by running the commands below:

| Check | Command or method | Result |
|---|---|---|
| Reachable | `curl -sL` on the direct zip URL | HTTP 200 |
| Size | `curl` download, then byte count | 45,622,418 bytes (about 45.6 MB) |
| Archive contents | `unzip -l` | one file, `online_retail_II.xlsx`, 45,622,278 bytes |
| Sheets | parse `xl/workbook.xml` inside the xlsx | `Year 2009-2010`, `Year 2010-2011` |
| Rows | count `<row` tags in each sheet XML (includes header) | 525,462 and 541,911 (about 1.07 million transaction lines in total) |
| Date ranges | read the InvoiceDate column (E) in each sheet XML | sheet 1: 1 Dec 2009 to 9 Dec 2010. Sheet 2: 1 Dec 2010 to 9 Dec 2011 |
| Overlap | count lines dated 1 to 9 Dec 2010 in each sheet | 22,523 lines in each sheet, the same count. The 9 days appear in both sheets |
| Malformed dates | count InvoiceDate values below serial 1000 (year 1899) | 1 in each sheet. These are dropped by the window filter |
| License | read the dataset page | CC BY 4.0 |

Correction note (2026-10-29, added after the data acquisition step; the original text above is kept as written):

- The row "Malformed dates" above is wrong. A direct check of the raw sheet XML (all numeric values in column E, both sheets) found no value below serial 1000. The smallest serials are 40,148.32 (sheet 1) and 40,513.35 (sheet 2). No 1899 dates exist, and the window filter drops 0 rows. The earlier count of 1 per sheet is not reproduced. See DATA.md section 9.
- The "about 1.07 million lines" is the raw total (525,461 + 541,910 = 1,067,371). After the sheet-overlap rule (section 3, rule 0), the combined table has 1,044,848 lines (DATA.md section 4).
- The `digest` package in `data/download.R` was replaced by the system `shasum` command, so the download script needs no extra R package.
- The dataset citation and CC BY 4.0 license were re-checked on the UCI page on 2026-10-29 (DATA.md section 1).

Large enough: about 1.07 million lines, about 2 years of weekly history (roughly 104 weeks), and a product catalogue that the pipeline will count. Launches (new products) are counted by the pipeline, not assumed here. The design requires at least 500 test launches that have 12 weeks of history plus 4 weeks of targets observed. If the data does not reach 500, the protocol still runs, the shortfall is stated in the README, and no claim is made beyond the sample.

Size rule: the zip (45.6 MB) and the xlsx (45.6 MB) are above the 5 MB limit. They are never committed. `data/download.R` fetches them into `data/raw/`, which is in `.gitignore`. Only the cleaned weekly table, if it is under 5 MB, may be written to `data/processed/`. Otherwise the pipeline rebuilds it from the raw file.

Backup datasets (not used unless the primary fails):

- M5 (Walmart item-store daily sales). Mirror: https://github.com/Nixtla/m5-forecasts/raw/main/datasets/m5.zip. Verified 2026-10-29: the URL redirects and the final response is HTTP 200, size about 50.2 MB. The license for this competition data is governed by the Kaggle competition rules. I did not verify those terms for research reuse, so M5 is not the primary dataset. It is a fallback only if its terms are checked and found compatible.
- Rossmann and Favorita (Kaggle). Direct Kaggle URLs returned HTTP 404 to unauthenticated curl, so reachability and terms are not verified. Excluded for now.

Limits of this dataset (to be stated in the README):

- One UK wholesaler, not a store chain. Customers are mostly businesses.
- "New product" means "first sale in this dataset after the burn-in period". It does not mean the product was launched that week.
- Two years of history, and the data is from 2009 to 2011.
- Product codes are the retailer's own codes.

## 3. Data cleaning and definitions (fixed before results)

These rules are written down now and are not changed after seeing test results.

0. Sheet overlap. Sheet 1 (`Year 2009-2010`) and sheet 2 (`Year 2010-2011`) both contain the same 22,523 lines dated 1 to 9 December 2010. Rule: take sheet 1 for InvoiceDate before 1 December 2010, and sheet 2 for InvoiceDate from 1 December 2010 onward. Then the 9 overlapping days are counted once. The pipeline also checks that the two sheets agree on those 9 days (same line count) and stops if they do not.
1. Keep lines whose StockCode looks like a product code (5 digits, optionally followed by letters). Drop non-product codes such as POST, D, M, BANK CHARGES, PADS, DOT and similar service codes.
2. Drop lines with Price <= 0, missing StockCode, or an InvoiceDate that does not fall inside 1 December 2009 to 9 December 2011. (Dated note, 2026-10-30: the parenthetical that this removes malformed 1899 dates is wrong. No such dates exist in the data, as DATA.md section 9 and the cleaning counts show. The rule itself is unchanged and the window filter removes no rows for that reason. See section 12.6.)
3. Invoices starting with "C" are cancellations. Primary demand = sum of positive Quantity on sales lines. Returns are excluded from demand. Robustness variant: net of returns.
4. Week = Monday-start calendar week. Week 1 starts Monday 30 November 2009. The last partial week in the data is dropped.
5. Series = one row per StockCode per week, units = primary demand. Zeros are filled in for weeks with no sales. Each product's series starts at its first week of data.
6. Burn-in = weeks 1 to 8 (December 2009 to late January 2010). A product is eligible to be a "launch" only if it has zero primary demand in the burn-in. This removes products that were already selling before the window and so are not truly new.
7. Launch week L_p = first week with at least 1 unit of primary demand after the burn-in. Launch-eligible products must have L_p >= 9.
8. Each product has one description for analog matching: the most frequent Description value among its lines dated on or before the origin week. Log median price for the same product is computed from prices in weeks on or before the origin week only.

## 4. Analysis components (at least 4 distinct)

Each component is a separate script in `src/` with its own output in `results/`.

**Component A. Cleaning, launch detection and cohort construction.** Builds the weekly table, applies the rules in section 3, counts launches, and reports how many launches reach each value of k. Also writes the list of launch products and their weeks, so the other components use the same cohort.

**Component B. Cold-start curve (main result).** For k in {1, 2, 3, 4, 6, 8, 12, 16, 20, 26}, each test launch is forecast from its first k weeks, with targets at horizons h = 1, 2, 3, 4. Models compared:

- M0 Naive carry-forward: last observed week's units.
- M1 Own mean: mean of the product's own k weeks, with a negative binomial interval from its own variance.
- M2 Per-series negative binomial: separate model per product fitted to its own weeks only.
- M3 Global negative binomial GLM (complete pooling): one model across all products, with features log(1 + mean of first k weeks), k, h, log median price and the week-of-year of launch. Fitted on development launches only.
- M4 Partial pooling, hierarchical negative binomial (primary model): log mean for product p at horizon h is a global intercept plus feature effects, plus a product random effect u_p ~ Normal(0, tau^2), plus an analog prior offset (component C). Fitted by Bayesian sampling (cmdstanr preferred) or by empirical Bayes (glmmTMB) if cmdstanr is not available. The fitting method is fixed now: primary = cmdstanr, with 4 chains, 2,000 iterations per chain after 1,000 warm-up, and a check that R-hat < 1.01 and no divergent transitions. If these checks fail, that run is reported as failed, not repaired by changing settings.
- M5 Analog-only prior (ablation): forecast = the analog cohort's mean weekly curve at the same weeks-since-launch, with no product data.

Metrics for each model, k and h:

- WAPE (weighted absolute percentage error) = sum of absolute errors divided by sum of actual units.
- Bias = mean of (forecast minus actual).
- 80% and 50% interval coverage, and mean interval width.
- Interval score for the 80% interval (Gneiting and Raftery) and an approximate CRPS from predictive draws.

The primary headline number is WAPE for M4 versus M0 and M3 at k = 4, pooled over h = 1 to 4, with a product-clustered bootstrap confidence interval (2,000 resamples, resampling products, not rows).

**Component C. Analog prior construction.** For each origin, the analog set is the K most similar launches that happened before the origin week and whose weeks 1 to k + 4 since launch all end on or before the origin week. An analog's future weeks are never used, even though they exist in the data. Similarity combines (a) cosine similarity of TF-IDF vectors built from Description text, (b) absolute difference in log median price, and (c) same launch quarter. Weights and K are chosen on development launches only. Ablations: text similarity off (time and price only), K = 10, 20 and 40, and no analog prior at all (M4 with the analog offset removed, which becomes a random-intercept model).

**Component D. Pooling diagnostics.** Estimates tau (the between-product spread) and reports how far each product's forecast moves from its own mean toward the prior (the shrinkage factor). Also checks whether the posterior tau is distinguishable from zero. If tau is near zero, the hierarchical model reduces to a global model, and this is reported as a finding.

**Component E. Interval calibration.** Reports coverage and sharpness by k and h for each model. Then applies split-conformal recalibration: development-set residuals set a multiplicative width factor per k. The recalibrated intervals are evaluated once on test launches. Before and after numbers are both reported.

**Component F. Robustness grid.** Each variant re-runs components B and E with one setting changed: burn-in of 13 weeks instead of 8; launch threshold of 5 units instead of 1; returns netted against demand; UK customers only; excluding the top 1% of products by volume; Poisson instead of negative binomial; K = 10, 20 and 40; and a random product split instead of the time split. The random split is run only as a warning check, to show how much a leaky split would overstate performance. A headline result is called fragile if its sign or its ranking of M4 against M0 and M3 changes under any variant.

**Component G. Simulation layer (labelled method check, not a demand result). [Removed 2026-10-30, see section 12.1. The text below is kept as written.]** Generates synthetic products with a known tau and known analog structure, then checks that component D recovers tau and that M4 beats M2 when pooling should help. Output files are named `sim_*` and every figure and table from this component carries the label "SIMULATION". Simulation results are never reported as evidence about real demand.

**Real-data known-truth benchmark (within component B).** Mature products (sales in every week of the window) are truncated to pretend they launched at a chosen week. Their later weeks are real observed demand, so they serve as a second held-out set with known truth. This is reported separately from the launch test set.

## 5. Evaluation protocol (fixed before any results)

1. Time split on launch week. Development launches: L_p between week 9 and week 52 (December 2009 to November 2010). Test launches: L_p from week 53 onward. Test launches are used only after all hyperparameters are frozen.
2. Rolling origins: for each test launch and each k, the origin is week L_p + k - 1. Information used at the origin is restricted to weeks up to the origin. No product, analog or hyperparameter may use a later week. A leakage test in `src/` checks this by recomputing features after truncating the data at the origin and confirming the features are unchanged.
3. Training-row cutoff for every fitted model (M2, M3, M4, the analog weights and the conformal scale). A training row is kept only if its target week is at or before week 52, the last week of the development period. Development launches whose targets run past week 52 are therefore dropped from fitting, not just from evaluation. This stops calendar information from the test period, such as the Christmas 2010 level, from reaching the test forecasts through the week-of-year term. The leakage test in `src/` also checks that no fitted object contains a row with target week above 52.
4. Development set is used to pick: analog weighting, K, and the priors for the Bayesian model. The burn-in and launch definitions are fixed at the values in section 3. The test set is evaluated once per frozen configuration.
5. Freeze: before the test evaluation, the configuration files and code are committed to git. The commit hash is written to `results/PROTOCOL_LOCK.txt`. Any change after that point is labelled as a post-hoc change in the README. The protocol in this section should be committed before results exist (see section 9), so its date can be checked against git history.
6. Primary metric: WAPE at k = 4, pooled over h = 1 to 4, for M4 against M0 and M3. Primary decision rule: M4 counts as better at cold start if its WAPE is at least 3 percentage points lower than the better of M0 and M3, and the product-clustered 95% bootstrap interval for the difference excludes zero.
7. Secondary metrics: the full cold-start curve, interval coverage at 80% and 50%, interval score, and the real known-truth benchmark.
8. Seed: 20261029 for all random steps. Stan seed is set the same way.

## 6. Failure criteria (decided now)

The project is reported as a failure, or a partial failure, if any of these occur. Each is reported in the README with its numbers.

- F1. M4 does not beat the better of M0 and M3 at k = 4 by 3 or more WAPE points with a confidence interval excluding zero. Report: partial pooling gave no measurable cold-start gain on this data.
- F2. The analog-only prior (M5) is not better than a global-average prior at k = 4. Report: analog matching does not carry information on this data.
- F3. Posterior tau is indistinguishable from zero. Report: the hierarchical structure does not help beyond a global model here.
- F4. 80% intervals after conformal recalibration have test coverage outside 0.72 to 0.88. Report: intervals are not calibrated, even after recalibration.
- F5. The sign or the ranking of M4 against M0 and M3 changes in any robustness variant. Report: the result is fragile.
- F6. Fewer than 500 test launches have k = 12 weeks of history and 4 weeks of targets. Report: the sample is too small for the k = 12 point, and that point is not interpreted.
- F7. Bayesian convergence fails (R-hat >= 1.01 or divergent transitions). Report that M4 failed to fit, and give the empirical Bayes result as a separate, clearly labelled row.

Any of F1 to F7 is a legitimate result. The README must not describe a failed criterion as a success.

## 7. Why this is hard to reproduce in a day

The data is real retail data, which is messy in ways that take time to handle. Service codes, cancellations, returns and invoice quirks all have to be classified and documented, and each choice moves the launch count. Launch detection depends on a burn-in rule, because a product can look new when it was only absent from the early data. Getting the origin-based test right takes care: every feature must be recomputed from data that existed at that week, and the leakage test has to be written and passed. The hierarchical model needs a Bayesian fit with convergence checks, a prior built from text and price similarity, and a conformal step, and each of these has its own failure modes. The robustness grid repeats the whole pipeline over about ten variants, and the failure criteria must be applied honestly to each. Writing the plain-English explanation for each step, and a limitations section that is accurate for a two-year single-retailer sample, adds more work. Doing all of this carefully, with a protocol that was locked before results were seen, is weeks of work, not a day.

## 8. Repository layout

```
new-product-demand-partial-pooling/
  DESIGN.md                 (this file)
  README.md                 (question, data, method, results, limits, what failed; written last)
  data/
    download.R              (fetches the zip into data/raw/, checks size and sheet names)
    prep_raw.R, feasibility_check.R
    raw/                    (gitignored, never committed)
    interim/                (gitignored, rebuilt by the pipeline)
    summary/                (cleaning counts, committed)
  src/
    00_config.R             (fixed settings)
    lib_pipeline.R          (shared functions: cleaning, analogs, M0 to M5g, M4 fit and predict)
    01_clean_and_launches.R (component A)
    02_features_analogs.R   (component C, with leakage test)
    03_models_baselines.R   (M0 to M3, M5, and M4 for each k)
    04_pooling_diagnostics.R (component D; M4 itself is fitted in src/lib_pipeline.R, not in a separate script)
    05_cold_start_eval.R    (component B and metrics)
    06_calibration.R        (component E)
    07_robustness.R         (component F)
    08_simulation_check.R   (removed 2026-10-30, see section 12.1)
    09_figures.R            (ggplot2 figures, final output in R)
    10_posthoc_concentration.R, 11_known_truth_benchmark.R, 12_posthoc_checks.R, 13_m4_numerical_checks.R, 14_regeneration_check.R (post-hoc, section 11 and 12)
  results/
    PROTOCOL_LOCK.txt
    *.csv                   (all numbers in the README come from these files)
  figures/
```

Tooling: R. Installed packages to add: readxl, data.table, MASS, glmmTMB, cmdstanr (if the Stan toolchain is available), ggplot2. Current local check: readxl is not installed, data.table is installed. Python is used only for a one-off xlsx row count during design and is not part of the project.

## 9. Commit and publication rules

- Public repo under jessieyang22 on GitHub. Push once results and the README exist. Before any test-set evaluation, DESIGN.md and the configuration files should be committed locally (git init in the project folder), which timestamps the protocol. Nothing was committed at design time, and the GitHub remote is not created at this step.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. [Dated note, 2026-10-30: this line is superseded. From 2026-10-30 commits end with `Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>`, which is the attribution the session requires and which all earlier commits used. See section 12.5.]
- No raw data committed. No claim in the README without a matching CSV in `results/`.
- No analogies or metaphors in the README or any prose. Every step is explained in plain English.

## 10. Amendments made before the test evaluation (dated 2026-10-30)

These notes were written after the development-only steps (scripts 01 and 02) and before any
test-set prediction or metric was produced. The commit that contains this section, and the
code and config in `src/`, is the protocol lock (see `results/PROTOCOL_LOCK.txt`).

**A1. Fitting method for M4.** cmdstanr is not installed and CmdStan is not available on this machine. glmmTMB could not be installed (its dependencies `nloptr` and `lme4` failed to build). So the Bayesian fit in section 4 (component B, M4) was not run. No R-hat is reported. M4 is instead a random-intercept negative binomial fitted by maximum marginal likelihood (empirical Bayes). The product effect is integrated on a 61-point grid over N(0,1) scaled by tau. Convergence is the code from `optim` (BFGS). Failure criterion F7 applies to this optimiser. The Bayesian version is not run and is not claimed.

**A2. Analog offset in M4.** The analog curve (log(1 + mean units of the analog set at the same week since launch)) enters M4 as a fixed covariate with an estimated coefficient, not as a fixed offset with coefficient 1.

**A3. Analog similarity.** Text similarity is cosine similarity of TF-IDF vectors of the most frequent Description as of the origin week. The IDF is estimated only from descriptions sold in burn-in weeks 1 to 8, so no later text enters the weights. The similarity score is w_text * cosine - w_price * |difference in log median price| + w_quarter * (same launch quarter), with w = (1, 0.5, 0.25). These weights were fixed before any result and were not tuned. K was chosen on development launches only, from {10, 20, 40}, by the analog-only forecast WAPE at k = 4 (`results/C_dev_K_selection.csv`). K = 40 was chosen. The differences between K values are small (see that file). Test-set K variants 10 and 20 are reported in the robustness grid.

**A4. Analog pool and fallback.** A launch is an analog for product p at origin o if its launch week is at or before L_p - 4. This is exactly the rule that its weeks 1 to k+4 all end on or before the origin. When no analog exists, the analog curve is the global average over development launches at each week since launch (weeks with data up to the training cutoff). The number of products that use the fallback is recorded in `info` (`fb_analog_train`, `fb_analog_test`).

**A5. Point forecast.** Every model is scored on its predictive mean. M0, M1, M2 and M3 use their NB mean. M4 uses the posterior predictive mean. M5 and M5g use their analog or global mean. The same rule applies to all models.

**A6. Dispersion for models without their own.** M0, M5 and M5g use the dispersion of the pooled M3 GLM, fitted on development target rows. M1 uses a method-of-moments dispersion from its own weeks (or the global value at k = 1, where the variance is undefined). Series with variance at or below the mean are treated as Poisson-like (dispersion 1e4). M2 uses the maximum likelihood dispersion of an intercept-only NB on its own weeks, clipped to [0.05, 1e4]. M2 falls back to the global dispersion at k <= 2. Counts of these fallbacks are stored in the `fb` column of the predictions. Note: M1 and M2 have identical point forecasts, because the intercept-only NB mean equals the sample mean. They differ only in their intervals.

**A7. M3 pooling.** M3 is one NB GLM fitted once across all k on development target rows (h = 1 to 4, target week at or before 52), as DESIGN.md section 4 says. Its features are log(1 + own mean), k, h, log median price, and sine and cosine of the launch day-of-year.

**A8. M4 pooling and prediction.** M4 is refitted for each k on development rows (history and target weeks, all at or before week 52). For a test product, its random effect is the posterior given its own first k weeks only, with the development-fitted hyperparameters held fixed. The product's target weeks are never used.

**A9. Conformal recalibration (component E).** Intervals are the 10 to 90 and 25 to 75 quantiles of 1000 predictive draws around the median. Recalibration multiplies the half-widths by a scale c, the smallest value on a grid (step 0.01) at which the development coverage reaches the nominal level. c is set on development (train-set) predictions and applied once to the test predictions. For M3 and M4 these development predictions are in-sample, so their calibration is optimistic, and this is stated in the README.

**A10. Failure criteria, operational definitions.** F1 uses DESIGN.md section 5 item 6. F2 is triggered when M5 WAPE is greater than or equal to M5g WAPE at k = 4. F3 is triggered when the likelihood-ratio test of tau = 0 (boundary 50:50 mixture, one degree of freedom) gives p >= 0.05 at k = 4. F5 uses the time-split variants only. The random-split variant is reported as a warning check. F6 uses the test count at k = 12 with 4 target weeks. F4 uses the 80% conformal test coverage of M4 at k = 4, within [0.72, 0.88].

**A11. Robustness variants.** These run at k = 4 only, because F5 is judged on the k = 4 headline. "Drop top 1% of products" uses volume in the development period (weeks 1 to 52) only, so that test-period volume does not enter the cohort. "Launch threshold 5" means the launch week is the first week with at least 5 units. "Returns netted" floors each product-week at zero after netting. "Poisson" replaces the NB likelihood with a Poisson likelihood in every model. The random split puts a fixed random 59% of eligible products in training, with no training cutoff at week 52. It is a leaky warning check only.

**A12. Known-truth benchmark (mature products truncated to pretend launch).** Not run in this pass. Its design is not specified precisely enough in section 4 to run without further choices. The primary validation is the held-out time split (section 5), which satisfies the requirement for a held-out set. The README says this plainly.

**A13. Simulation layer (component G).** Run as a labelled method check (`results/sim_*`). Simulated results are not evidence about real demand.

**A14. Cleaning rule 1 and DCGS codes.** Kept exactly as written in section 3 rule 1. The 34 DCGS codes (157 lines) are therefore dropped. DATA.md section 6 asks the owner to decide. This is left for Jessie, and the README reports it as an open decision.

**A15. Week-of-year term.** The seasonal feature is the day-of-year of the launch week, as section 4 (M3) says. It is not the calendar week of each target. The training cutoff still stops test-period calendar information from reaching the fit.

**A16. Commit attribution.** Commit messages end with the Co-Authored-By line that the session specifies, Claude Haiku 5.5, which matches the repository's previous commit. Section 9 of this file names Claude Sonnet 5.5. The session's attribution rule takes precedence, and the README notes the difference.

**A12 update (dated 2026-10-30, post-hoc).** A12 above is kept as written. Its benchmark is now specified and run as section 11. Section 11 was written after the test-set results in section 5 had been read. It is therefore post-hoc, and it does not change F1 to F7 or any pre-registered result.

## 11. Post-hoc known-truth benchmark and reproducibility check (dated 2026-10-30, written after the test results were read)

This section is post-hoc. It was written after the test-set results (section 5) and their CSVs in `results/` were produced. It fixes the choices below before the benchmark is run. The commit that contains this section precedes the first run of `src/11_known_truth_benchmark.R`. Output files use the prefix `KT_`.

**11.1 Purpose.** A real-data check that the forecasting code recovers the truth on products whose later weeks are observed. A pretend launch is placed on steady products, and the truth is their real later demand. This tests forecasting from k weeks of a steady product. It is not a cold-start test (see 11.6).

**11.2 Selection (development period only).** An active product is one with positive units in at least 45 of the 52 development weeks (weeks 1 to 52). Counts, from `src/11`:

- Products with positive units in every week from 1 to 105: 0.
- Products with positive units in every week from 1 to 52: 0.
- Products with positive units in at least 45 of weeks 1 to 52: 638.

The selection never looks at weeks 53 or later, because that would condition on the outcome. The 638 products cannot be launch products. At most 44 weeks (9 to 52) can be active for a product with no burn-in sales, so any product with 45 or more active weeks has sales in burn-in and is excluded from the launch cohort by the burn-in rule.

**11.3 Pretend-launch week.** Each active product is assigned to one pretend-launch week L* from {53, 60, 67, 74}, by a seeded random balanced assignment (seed 20261029; `sample(rep(c(53, 60, 67, 74), length.out = n))`). Each product appears once. The targets are weeks L* + k to L* + k + 3. Those weeks end by week 105 for every k in the K grid, since L* + k + 3 is at most 103.

**11.4 History and truth.** History is the real units in weeks L* to L* + k - 1 only. Truth is the real units in the next four weeks, including zeros. No forecast uses a week after its origin.

**11.5 Fits and a consistency check.** Every fitted object comes from development launches only, using the same functions as the test run: `prepare_context`, `prepare_pooled` (M3 pooled across k) and `fit_m4` (M4, per k). Before any benchmark prediction, the script rebuilds these and compares them with `results/` and `data/interim/run_baseline.rds`: the M3 coefficients, the global dispersion, and the M4 tau and log-likelihood at every k. It stops if any value differs.

**11.6 Analog pool and mismatch.** The benchmark products are appended to the context as pretend launches. The analog pool is restricted to real launches (development and test) with L <= L* - 4. The pretend products are never analogs for each other. Price and description are taken as of the origin using sales lines dated on or before the origin. This includes pre-L* lines, which is the one place where pre-L* information enters. The main mismatch is that the launch shape terms (log_s and the analog and global curves) describe the first weeks of a launch. Steady products have no such shape, so M4, M5 and M5g are expected to be disadvantaged. Carry-forward may win for that reason alone. This benchmark therefore does not support or refute partial pooling for cold start.

**11.7 Outputs and rule.** For every model and every k in the K grid: WAPE pooled over h = 1 to 4, bias, 80% and 50% coverage, and mean width (`results/KT_known_truth_by_model_k.csv`). Also by L* at k = 4 (`results/KT_by_Lstar_k4.csv`). The k = 4 contrast uses the section 5 rule (M4 against the better of M0 and M3, a 3-point margin, and a product-clustered bootstrap with 2,000 resamples and seed 20261029). It is reported as a secondary check with no confirmatory verdict (`results/KT_primary_k4_contrast.csv`).

**11.8 Limits.** One pretend-launch week per product, so each L* subset has about 160 products. The products are steady sellers, so they are likely easier to forecast than real launches. Cancellations follow rule 3 (cancellations are not netted in the baseline).

**11.9 Reproducibility re-run (not a new analysis).** The full chain (`data/prep_raw.R`, `data/feasibility_check.R`, `src/01` to `src/10`) is re-run from the raw zip, which is checked against its published SHA-256. Each committed file under `results/` and `data/summary/` is compared with the copy from before the re-run. The result is written to `results/R_reproducibility_check.csv`. Differences in timestamps or PNG bytes are classified and explained, not counted as numeric differences.

## 12. Amendments after review (dated 2026-10-30, post-hoc)

These amendments were written after an external review of the completed run. They do not change the pre-registered decisions in sections 5 and 6, and the headline verdict (F1 triggered, negative) is unchanged. Each new analysis is labelled post-hoc in its script and in the README.

**12.1 Simulation layer removed.** Component G (`src/08_simulation_check.R` and its outputs `results/sim_*`) generated fully synthetic products. The project rule is that no synthetic data stands in for a real result, and that simulation is allowed only as a method layered on real data. The layer did not meet that rule, so it is removed from the pipeline. Its history stays in git. No simulated number is reported. Rebuilding it on real weekly series is possible future work.

**12.2 Failed M4 fits are labelled.** The four M4 fits at k = 8, 12, 16 and 20 fail the post-hoc sanity check (section 5.1 of the README). In `src/05` and `src/06`, their metric and calibration cells are now blank and marked `posthoc_failed`. The raw predictions remain in `data/interim/run_baseline.rds`. The flag is defined once in `src/lib_pipeline.R` (`m4_posthoc_failed_k`).

**12.3 F3 corrected check (post-hoc).** The original F3 null (`design_m4` with tau = 0) has no product-level information, so rejecting tau = 0 is close to guaranteed and the original F3 row says little. `src/13` adds the product's own mean (`log1p_own`) to both the random-effect model and its null. The result is in `results/F3_nested_spread_check_k4.csv`. The original F3 row in `results/B_failure_criteria_F1_F3_F6_F7.csv` is kept unchanged.

**12.4 Numerical checks (post-hoc).** `src/13` compares the M4 quadrature grids (61, 121, 201 and 401 points on [-6, 6], and 321 points on [-8, 8]) at k = 4 and k = 8. It also runs multi-start checks and a netted-variant run with product 23166 removed from the test set. `src/12` adds a conformal step check, a leave-one-product-out check and data facts. `src/11` (known-truth benchmark, section 11) is now run; its consistency check had a naming bug, fixed in commit `5b7319f`.

**12.5 Commit attribution.** Section 9 is partly superseded. Commits made up to 2026-10-30 end with `Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>`, because the session attribution rule named that model. Commits made for the publication pass (2026-10-31) end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`, as the owner's publication instruction specified. Messages in the earlier commits are unchanged by the history rewrite (README section 1), so both trailers appear in the history. This is an open item for the owner (README section 9).

**12.6 Rule 2 date note.** Rule 2 in section 3 is correct as a window filter. The 1899 dates it mentions do not exist in the combined data (DATA.md section 9), so the filter removes no rows for that reason.

**12.7 Reproducibility check.** Section 11.9 is carried out as specified on 2026-10-31. A fresh copy of the repository (tracked and untracked source files only, no `results/`, `data/interim/`, `figures/` or `data/summary/`) was made in a scratch folder. The chain (`data/download.R` through `src/13`, the order in README section 8) was run there. `data/download.R` re-downloaded the zip from UCI and checked its size and sheet names. `src/14_reproducibility_check.R` compares every CSV, TXT and PNG in `results/`, `data/summary/` and `figures/` with the fresh output and writes `results/R_reproducibility_check.csv`. Its results are in README section 5.7. The earlier file name `results/R_regeneration_check.csv` (commit `8e0ac8e`) was never written to the repository and is not used. The regeneration script that compared against git history was replaced.

**12.8 Ablations not run.** Two component C ablations in section 4 were never run: text similarity off (time and price only), and M4 with no analog term. They are listed as not run in the README.

**12.9 Run time.** The full chain time is not in this file. The README gives a single observed figure, labelled as observed on a loaded machine.
