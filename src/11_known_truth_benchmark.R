# src/11_known_truth_benchmark.R
#
# POST-HOC KNOWN-TRUTH BENCHMARK (DESIGN.md section 11). Added after the test results had been read.
# NOT pre-registered. It does not change F1 to F7 or any result written by src/03 to src/10.
#
# Idea: take steady products (active in >= 45 of the 52 development weeks), pretend each one
# launched at a chosen week L*, forecast its next k weeks from real history, and score against
# its real later demand. The truth is observed, so no simulation is involved.
#
# Fits use development launches only. The fitted objects are rebuilt here and checked against
# data/interim/run_baseline.rds before any benchmark prediction is made.
#
# Run from the project root: Rscript src/11_known_truth_benchmark.R

source("src/lib_pipeline.R")
suppressPackageStartupMessages(library(data.table))

ANALYSIS_LABEL <- "POST-HOC known-truth benchmark (DESIGN.md section 11); not pre-registered"
B_BOOT         <- 2000L
BENCH_LSTAR    <- c(53L, 60L, 67L, 74L)
ACTIVE_MIN     <- 45L
TOL            <- 1e-6

cfg <- CFG_DEFAULT
set.seed(cfg$seed)
ctx <- prepare_context(cfg)
pre <- prepare_pooled(ctx, K_GRID, cfg$K)     # built with the ORIGINAL find_analogs (before any override below)
N_REAL <- nrow(ctx$launch)

# ---------------------------------------------------------------
# 1. Consistency check: rebuilt fits must match the saved baseline run
# ---------------------------------------------------------------
R0 <- readRDS("data/interim/run_baseline.rds")
m3_ok <- isTRUE(all.equal(unname(coef(pre$m3)), unname(R0$m3_coef), tolerance = TOL)) &&
  isTRUE(all.equal(pre$theta_global, R0$m3_theta, tolerance = TOL))
stopifnot(m3_ok)

fits4 <- list()
fit_check <- list()
for (k in K_GRID) {
  set.seed(cfg$seed + k)
  f4 <- fit_m4(pre$rows[[as.character(k)]], family = cfg$family, use_re = TRUE)
  fits4[[as.character(k)]] <- f4
  kk <- k
  s <- R0$info[k == kk]
  stopifnot(nrow(s) == 1L)
  fit_check[[as.character(k)]] <- data.table(
    k = k, tau_saved = s$tau, tau_rebuilt = f4$tau,
    loglik_saved = s$m4_loglik, loglik_rebuilt = f4$loglik,
    conv_saved = s$m4_convergence, conv_rebuilt = f4$convergence,
    pass = isTRUE(all.equal(unname(s$tau), unname(f4$tau), tolerance = TOL)) &&
      isTRUE(all.equal(unname(s$m4_loglik), unname(f4$loglik), tolerance = TOL)) &&
      s$m4_convergence == f4$convergence
  )
}
fit_check <- rbindlist(fit_check)
print(fit_check)
stopifnot(all(fit_check$pass))
fwrite(fit_check[, .(k, tau_saved, tau_rebuilt, loglik_saved, loglik_rebuilt, conv_saved, conv_rebuilt, pass)],
       "results/KT_fit_consistency_check.csv")

# ---------------------------------------------------------------
# 2. Selection: steady products, development period only
# ---------------------------------------------------------------
cl  <- load_clean_lines(cfg)
x   <- cl$lines
dem <- x[, .(units = max(0, sum(units_line))), by = .(StockCode, week)]

n_every_105 <- sum(dem[units > 0, .(nw = uniqueN(week)), by = StockCode]$nw == 105L)
dev_nw      <- dem[week >= 1L & week <= 52L & units > 0, .(nw = uniqueN(week)), by = StockCode]
n_every_52  <- sum(dev_nw$nw == 52L)
active      <- sort(dev_nw[nw >= ACTIVE_MIN, StockCode])
n_active    <- length(active)
stopifnot(!any(active %in% ctx$launch$StockCode))   # steady products are never launch products

sel_counts <- data.table(
  rule = c("sold in every week 1 to 105 (literal rule, whole window)",
           "sold in every week 1 to 52 (development period)",
           "sold in at least 45 of weeks 1 to 52 (used)"),
  n_products = c(n_every_105, n_every_52, n_active)
)
print(sel_counts)
fwrite(sel_counts, "results/KT_selection_counts.csv")

# ---------------------------------------------------------------
# 3. Pretend-launch weeks: one L* per product, seeded balanced assignment
# ---------------------------------------------------------------
set.seed(cfg$seed)
Lstar <- sample(rep(BENCH_LSTAR, length.out = n_active))
stopifnot(all(Lstar + 26L + H_MAX - 1L <= LAST_WEEK))   # every k in the grid stays inside week 105

# ---------------------------------------------------------------
# 4. Append the steady products to the context as pretend launches
#    (their rows are never added to the development training set)
# ---------------------------------------------------------------
pids_new <- N_REAL + seq_len(n_active)
qtr_new <- vapply(Lstar, function(L) {
  d <- week_start_date(L)
  paste0(format(d, "%Y"), "-Q", (as.integer(format(d, "%m")) - 1L) %/% 3L + 1L)
}, character(1))
new_launch <- data.table(pid = pids_new, StockCode = active, L = Lstar, qtr = qtr_new)

U_new <- matrix(0, n_active, LAST_WEEK)
dj <- dem[StockCode %in% active]
dj[, j := match(StockCode, active)]
dj[, L_j := Lstar[j]]
dj <- dj[week >= L_j]
U_new[cbind(dj$j, dj$week)] <- dj$units

s_lines <- x[is_sale & StockCode %in% active]
s_lines[, j := match(StockCode, active)]
setorder(s_lines, j, week)
sp <- split(s_lines, s_lines$j)
DESC_new <- matrix(NA_character_, n_active, LAST_WEEK)
LP_new   <- matrix(NA_real_, n_active, LAST_WEEK)
for (key in names(sp)) {
  p <- as.integer(key)
  sd <- sp[[key]]
  a <- asof_one(sd$week, sd$Description, sd$Price, Lstar[p])
  DESC_new[p, Lstar[p]:LAST_WEEK] <- a$desc
  LP_new[p, Lstar[p]:LAST_WEEK]   <- a$lp
}

# Description vocabulary: keep the old vocabulary in its original order, then append new descriptions.
new_vocab <- unique(c(ctx$desc_vocab, unique(na.omit(as.vector(DESC_new)))))
DESC_IDX_new <- matrix(match(DESC_new, new_vocab), n_active, LAST_WEEK)
burn_docs <- x[week <= cfg$burn_last & is_sale & !is.na(Description), unique(Description)]
X_new <- build_text_matrix(new_vocab, burn_docs)

# Check: cosine similarity between old descriptions is unchanged by the appended vocabulary.
old_idx <- seq_len(min(200L, nrow(ctx$X)))
cos_old <- as.matrix(ctx$X[old_idx, ] %*% Matrix::t(ctx$X[old_idx, ]))
cos_new <- as.matrix(X_new[old_idx, ] %*% Matrix::t(X_new[old_idx, ]))
cos_max_diff <- max(abs(cos_old - cos_new))
stopifnot(cos_max_diff < 1e-10)

ctx_aug <- ctx
ctx_aug$launch <- rbindlist(list(ctx$launch[, .(pid, StockCode, L, qtr)], new_launch), use.names = TRUE)
ctx_aug$U <- rbind(ctx$U, U_new)
ctx_aug$LP <- rbind(ctx$LP, LP_new)
ctx_aug$DESC_IDX <- rbind(ctx$DESC_IDX, DESC_IDX_new)
ctx_aug$X <- X_new
ctx_aug$desc_vocab <- new_vocab
stopifnot(nrow(ctx_aug$launch) == N_REAL + n_active)

# ---------------------------------------------------------------
# 5. Analog pool restricted to real launches (overrides the lib version for this script only)
# ---------------------------------------------------------------
# The lib version would also draw from the appended pretend launches, which must not be analogs.
# Everything else is identical to find_analogs in src/lib_pipeline.R.
find_analogs <- function(ctx, pid, k, K) {
  L <- ctx$launch$L
  origin <- L[pid] + k - 1L
  pool <- which(L <= L[pid] - 4L & seq_along(L) <= N_REAL)   # real launches only
  pool <- pool[pool != pid]
  if (!length(pool)) return(integer(0))
  cfg <- ctx$cfg
  dT <- ctx$DESC_IDX[pid, origin]
  dA <- ctx$DESC_IDX[pool, origin]
  cosv <- numeric(length(pool))
  ok <- !is.na(dA) & !is.na(dT)
  if (any(ok) && cfg$w_text != 0) {
    cosv[ok] <- as.numeric(ctx$X[dA[ok], , drop = FALSE] %*% Matrix::t(ctx$X[dT, , drop = FALSE]))
  }
  pd <- abs(ctx$LP[pool, origin] - ctx$LP[pid, origin])
  pd[is.na(pd)] <- 0
  sq <- as.numeric(ctx$launch$qtr[pool] == ctx$launch$qtr[pid])
  score <- cfg$w_text * cosv - cfg$w_price * pd + cfg$w_quarter * sq
  o <- order(-score, pool)
  pool[o[seq_len(min(K, length(o)))]]
}

# Check: real test launches keep their analog sets after augmentation (the pool is unchanged for them).
set.seed(cfg$seed)
test4 <- make_sets(ctx, 4L)$test
chk <- sort(sample(test4, min(100L, length(test4))))
an_before <- lapply(chk, function(p) {
  # original definition (pool over all rows of the un-augmented context)
  L <- ctx$launch$L; origin <- L[p] + 3L
  pool <- which(L <= L[p] - 4L); pool <- pool[pool != p]
  dT <- ctx$DESC_IDX[p, origin]; dA <- ctx$DESC_IDX[pool, origin]
  cosv <- numeric(length(pool)); ok <- !is.na(dA) & !is.na(dT)
  if (any(ok)) cosv[ok] <- as.numeric(ctx$X[dA[ok], , drop = FALSE] %*% Matrix::t(ctx$X[dT, , drop = FALSE]))
  pd <- abs(ctx$LP[pool, origin] - ctx$LP[p, origin]); pd[is.na(pd)] <- 0
  sq <- as.numeric(ctx$launch$qtr[pool] == ctx$launch$qtr[p])
  score <- cfg$w_text * cosv - cfg$w_price * pd + cfg$w_quarter * sq
  pool[order(-score, pool)[seq_len(min(cfg$K, length(pool)))]]
})
an_after <- lapply(chk, function(p) find_analogs(ctx_aug, p, 4L, cfg$K))
analog_same <- vapply(seq_along(chk), function(i) identical(an_before[[i]], an_after[[i]]), logical(1))
analog_check <- data.table(check = "real test launches (k=4): analog sets identical before and after appending pretend launches",
                           n_checked = length(chk), n_identical = sum(analog_same), cosine_max_diff_old_vocab = cos_max_diff)
print(analog_check)
fwrite(analog_check, "results/KT_analog_preservation_check.csv")
stopifnot(all(analog_same))

# ---------------------------------------------------------------
# 6. Benchmark predictions, every k in the grid
# ---------------------------------------------------------------
preds <- list()
fb_rows <- list()
for (k in K_GRID) {
  set.seed(cfg$seed + k)
  glob <- pre$globs[[as.character(k)]]
  rows <- build_rows(ctx_aug, pids_new, k, LAST_WEEK, glob, cfg$K)
  stopifnot(max(rows$week) <= LAST_WEEK, min(rows$week) >= min(Lstar))
  fits <- list(m3 = pre$m3, theta_global = pre$theta_global, m4 = fits4[[as.character(k)]], glob_raw = glob$raw)
  p <- predict_all(ctx_aug, rows, fits, "benchmark", k)
  p[, lstar := ctx_aug$launch$L[pid]]
  preds[[as.character(k)]] <- p
  fb_rows[[as.character(k)]] <- data.table(k = k, n_products = n_active,
                                           fb_analog_benchmark = attr(rows, "n_fallback"))
  message("benchmark k=", k, " rows=", nrow(p))
}
P <- rbindlist(preds, fill = TRUE)
P[, abs_err := abs(point - y)]
saveRDS(P, "data/interim/KT_predictions.rds")

# ---------------------------------------------------------------
# 7. Metrics
# ---------------------------------------------------------------
metric_tab <- function(D, by_cols) D[, .(
  n_rows = .N, n_products = uniqueN(pid),
  wape = sum(abs_err) / sum(y), bias = mean(point - y),
  cov80 = mean(y >= q10 & y <= q90), cov50 = mean(y >= q25 & y <= q75),
  width80 = mean(q90 - q10), width50 = mean(q75 - q25),
  crps = mean(crps)
), by = by_cols]

by_model_k <- metric_tab(P, c("model", "k"))
by_model_k[, analysis := ANALYSIS_LABEL]
fwrite(by_model_k, "results/KT_known_truth_by_model_k.csv")

by_lstar_k4 <- metric_tab(P[k == 4L], c("model", "lstar"))
by_lstar_k4[, analysis := ANALYSIS_LABEL]
fwrite(by_lstar_k4, "results/KT_by_Lstar_k4.csv")

wide <- dcast(by_model_k, k ~ model, value.var = "wape")
print(wide)

# M4 fit sanity by k (post-hoc flag, as in src/05)
m4_sane <- rbindlist(lapply(K_GRID, function(k) {
  f <- fits4[[as.character(k)]]
  data.table(k = k, tau = f$tau, loglik = f$loglik, convergence = f$convergence,
             tau_above_10 = f$tau > 10)
}))
fwrite(m4_sane, "results/KT_M4_fit_by_k.csv")
fwrite(rbindlist(fb_rows), "results/KT_analog_fallback_counts.csv")

# ---------------------------------------------------------------
# 8. Product-clustered bootstrap contrasts at k = 4 (secondary, no confirmatory verdict)
# ---------------------------------------------------------------
product_sums <- function(D, k_val) {
  Dk <- D[k == k_val]
  Dk[, .(A = sum(abs_err), Y = sum(y)), by = .(model, pid)]
}
boot_setup <- function(ps, models) {
  pids <- sort(unique(ps$pid))
  Y <- ps[model == models[1], .(Y = Y[match(pids, pid)])]$Y
  A <- sapply(models, function(m) ps[model == m, A[match(pids, pid)]])
  colnames(A) <- models
  list(pids = pids, Y = Y, A = A)
}
boot_draws <- function(bs, B = B_BOOT, seed = cfg$seed) {
  set.seed(seed)
  n <- length(bs$Y)
  idx <- matrix(sample.int(n, n * B, replace = TRUE), nrow = n)
  Yb <- colSums(matrix(bs$Y[idx], nrow = n))
  Ab <- t(sapply(seq_len(ncol(bs$A)), function(j) colSums(matrix(bs$A[idx, j], nrow = n))))
  rownames(Ab) <- colnames(bs$A)
  sweep(Ab, 2, Yb, "/")
}
primary_contrast <- function(ps, k_val, target = "M4", comps = c("M0", "M3")) {
  bs <- boot_setup(ps, c(target, comps))
  W <- boot_draws(bs)
  point_w <- colSums(bs$A) / sum(bs$Y)
  best_point <- min(point_w[comps])
  diff_point <- point_w[target] - best_point
  best_b <- apply(W[comps, , drop = FALSE], 2, min)
  diff_b <- W[target, ] - best_b
  data.table(k = k_val, target = target, comparators = paste(comps, collapse = "/"),
             wape_target = point_w[target], wape_best_comparator = best_point,
             diff_pts = 100 * diff_point,
             ci_low_pts = 100 * quantile(diff_b, 0.025), ci_high_pts = 100 * quantile(diff_b, 0.975),
             n_products = length(bs$Y))
}
ps4 <- product_sums(P, 4L)
contr <- rbindlist(list(
  primary_contrast(ps4, 4L, "M4", c("M0", "M3")),
  primary_contrast(ps4, 4L, "M4", "M1"),
  primary_contrast(ps4, 4L, "M4", "M5"),
  primary_contrast(ps4, 4L, "M3", "M0"),
  primary_contrast(ps4, 4L, "M5", "M5g")
))
contr[, role := c("secondary check of the section 5 rule (not confirmatory)", "secondary", "secondary", "secondary", "secondary")]
contr[, rule_met_secondary := NA]
contr[1, rule_met_secondary := (diff_pts <= -3 & ci_high_pts < 0)]
contr[, analysis := ANALYSIS_LABEL]
print(contr)
fwrite(contr, "results/KT_primary_k4_contrast.csv")

cat("\nDone. Benchmark rows:", nrow(P), " products:", n_active, "\n")
