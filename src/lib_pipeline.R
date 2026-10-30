# src/lib_pipeline.R
# Shared functions for the cold-start pipeline. Numbered scripts in src/ source this file.
# Run every script from the project root, for example: Rscript src/05_cold_start_eval.R

suppressPackageStartupMessages({
  library(data.table)
  library(MASS)
  library(Matrix)
})

source("src/00_config.R")

W1_START    <- as.Date("2009-11-30")   # Monday; week 1 starts here (DESIGN.md rule 4)
LAST_WEEK   <- 105L                    # last full week (starts 28 Nov 2011)
DATA_START  <- as.Date("2009-12-01")
DATA_END    <- as.Date("2011-12-09")
N_DRAWS     <- 1000L
H_MAX       <- 4L
K_GRID      <- c(1L, 2L, 3L, 4L, 6L, 8L, 12L, 16L, 20L, 26L)
Z_GRID      <- seq(-6, 6, length.out = 61)   # quadrature grid for the product random effect
DZ          <- Z_GRID[2] - Z_GRID[1]
LOG_W_Z     <- dnorm(Z_GRID, log = TRUE) + log(DZ)
TRAIN_SHARE_RANDOM <- 0.59               # share of eligible products in the random-split check
GLOBAL_STEPS <- 30L

week_start_date <- function(w) W1_START + 7L * (as.integer(w) - 1L)
date_to_week    <- function(d) as.integer(floor(as.numeric(as.Date(d) - W1_START) / 7) + 1L)

logdens <- function(y, mu, theta, family) {
  if (family == "nb") dnbinom(y, size = theta, mu = mu, log = TRUE) else dpois(y, mu, log = TRUE)
}

# Same log density, written from the log mean (lmu) so that large linear predictors do not overflow.
logdens_lmu <- function(y, lmu, theta, family) {
  if (family == "nb") {
    lt <- log(theta)
    lse <- pmax(lt, lmu) + log1p(exp(-abs(lt - lmu)))   # log(theta + mu)
    lgamma(y + theta) - lgamma(theta) - lgamma(y + 1) + theta * (lt - lse) + y * (lmu - lse)
  } else {
    dpois(y, exp(lmu), log = TRUE)
  }
}

draw_fam <- function(mu_mat, theta, family) {
  # mu_mat: matrix; returns integer matrix of the same shape
  if (family == "nb") {
    th <- if (length(theta) == 1L) theta else rep(theta, times = ncol(mu_mat))
    matrix(rnbinom(length(mu_mat), size = th, mu = as.vector(mu_mat)), nrow = nrow(mu_mat))
  } else {
    matrix(rpois(length(mu_mat), lambda = as.vector(mu_mat)), nrow = nrow(mu_mat))
  }
}

# ------------------------------------------------------------------
# Component A: cleaning, launches, weekly series
# ------------------------------------------------------------------

load_clean_lines <- function(cfg) {
  x <- readRDS(file.path("data", "interim", "lines_combined.rds"))
  setDT(x)
  n_all <- nrow(x)
  x <- x[!is.na(StockCode) & grepl("^[0-9]{5}[A-Za-z]*$", StockCode)]          # rule 1
  n_code <- nrow(x)
  x <- x[!is.na(Price) & Price > 0 & !is.na(inv_date)]                            # rule 2
  x <- x[inv_date >= DATA_START & inv_date <= DATA_END]
  n_price_window <- nrow(x)
  if (isTRUE(cfg$uk_only)) x <- x[Country == "United Kingdom"]
  x[, week := date_to_week(inv_date)]
  x <- x[week >= 1L & week <= LAST_WEEK]
  x[, is_cancel := startsWith(Invoice, "C")]                                       # rule 3
  x[, is_sale := !is_cancel & !is.na(Quantity) & Quantity > 0]
  x[, units_line := if (isTRUE(cfg$netted)) as.numeric(Quantity) else ifelse(is_sale, as.numeric(Quantity), 0)]
  counts <- data.table(
    step = c("lines in combined table", "after rule 1 (product-like StockCode)",
             "after rule 2 (Price > 0, date in window)", "lines kept (weeks 1 to 105)"),
    lines = c(n_all, n_code, n_price_window, nrow(x))
  )
  list(lines = x, counts = counts)
}

build_text_matrix <- function(desc_vocab, burn_docs) {
  tok <- function(s) {
    t <- unique(strsplit(toupper(s), "[^A-Z0-9]+")[[1]])
    t[nchar(t) >= 2L]
  }
  burn_tok <- lapply(burn_docs, tok)
  df <- table(unlist(burn_tok))
  N <- length(burn_tok)
  vocab_tok <- lapply(desc_vocab, tok)
  terms <- sort(unique(unlist(vocab_tok)))
  idf_of <- function(t) {
    d <- if (t %in% names(df)) as.numeric(df[[t]]) else 0
    log((1 + N) / (1 + d)) + 1
  }
  idf <- vapply(terms, idf_of, numeric(1))
  names(idf) <- terms
  ii <- rep(seq_along(vocab_tok), lengths(vocab_tok))
  tt <- unlist(vocab_tok)
  jj <- match(tt, terms)
  X <- sparseMatrix(i = ii, j = jj, x = idf[tt], dims = c(length(desc_vocab), length(terms)))
  nrm <- sqrt(rowSums(X^2))
  nrm[nrm == 0] <- 1
  X <- Diagonal(x = 1 / nrm) %*% X
  as(X, "CsparseMatrix")
}

# As-of description (mode) and log median price for one product, using only
# sales lines dated on or before each week.
asof_one <- function(dw, dd, pp, Lp) {
  o <- order(dw)
  dw <- dw[o]; dd <- dd[o]; pp <- pp[o]
  ws <- unique(dw)
  vals_d <- character(length(ws)); vals_p <- numeric(length(ws))
  for (j in seq_along(ws)) {
    n_j <- findInterval(ws[j], dw)
    dsub <- dd[seq_len(n_j)]
    dsub <- dsub[!is.na(dsub)]
    if (length(dsub)) {
      tb <- table(dsub)
      vals_d[j] <- names(tb)[which.max(tb)]
    } else vals_d[j] <- NA_character_
    vals_p[j] <- median(pp[seq_len(n_j)])
  }
  wk <- Lp:LAST_WEEK
  idx <- findInterval(wk, ws)
  out_d <- rep(NA_character_, length(wk)); out_p <- rep(NA_real_, length(wk))
  ok <- idx > 0
  out_d[ok] <- vals_d[idx[ok]]
  out_p[ok] <- log(vals_p[idx[ok]])
  list(desc = out_d, lp = out_p)
}

prepare_context <- function(cfg, trunc_week = LAST_WEEK) {
  cl <- load_clean_lines(cfg)
  x <- cl$lines[week <= trunc_week]
  dem <- x[, .(units = max(0, sum(units_line))), by = .(StockCode, week)]
  burn_any <- dem[week <= cfg$burn_last & units > 0, unique(StockCode)]
  first_hit <- dem[week > cfg$burn_last & units >= cfg$launch_min,
                   .(L = min(week)), by = StockCode]
  n_first_hit <- nrow(first_hit)
  first_hit <- first_hit[!StockCode %in% burn_any & L >= cfg$dev_first]
  n_after_burn <- nrow(first_hit)
  drop_codes <- character(0)
  if (isTRUE(cfg$drop_top1)) {
    vol <- dem[week <= cfg$dev_last, .(vol = sum(units)), by = StockCode]
    thr <- quantile(vol$vol, 0.99)
    drop_codes <- vol[vol >= thr, StockCode]
    first_hit <- first_hit[!StockCode %in% drop_codes]
  }
  launch <- first_hit[order(L, StockCode)]
  launch[, pid := .I]
  launch[, qtr := {
    d <- week_start_date(L)
    paste0(format(d, "%Y"), "-Q", (as.integer(format(d, "%m")) - 1L) %/% 3L + 1L)
  }]
  n <- nrow(launch)
  U <- matrix(0, n, LAST_WEEK)
  d <- dem[StockCode %in% launch$StockCode]
  d[, pid := launch$pid[match(StockCode, launch$StockCode)]]
  d <- merge(d, launch[, .(pid, L)], by = "pid")
  d <- d[week >= L]
  U[cbind(d$pid, d$week)] <- d$units

  s <- x[is_sale & StockCode %in% launch$StockCode]
  s[, pid := launch$pid[match(StockCode, launch$StockCode)]]
  setorder(s, pid, week)
  sp <- split(s, s$pid)
  DESC <- matrix(NA_character_, n, LAST_WEEK)
  LP <- matrix(NA_real_, n, LAST_WEEK)
  for (key in names(sp)) {
    p <- as.integer(key)
    sd <- sp[[key]]
    a <- asof_one(sd$week, sd$Description, sd$Price, launch$L[p])
    DESC[p, launch$L[p]:LAST_WEEK] <- a$desc
    LP[p, launch$L[p]:LAST_WEEK] <- a$lp
  }
  desc_vocab <- unique(na.omit(as.vector(DESC)))
  DESC_IDX <- matrix(match(DESC, desc_vocab), n, LAST_WEEK)
  burn_docs <- x[week <= cfg$burn_last & is_sale & !is.na(Description), unique(Description)]
  X <- build_text_matrix(desc_vocab, burn_docs)

  # split assignment for the random-split check (fixed once, from the seed)
  set.seed(cfg$seed)
  u_split <- runif(n)

  list(cfg = cfg, launch = launch, U = U, LP = LP, DESC_IDX = DESC_IDX, X = X, desc_vocab = desc_vocab,
       n_lines = nrow(x), u_split = u_split, drop_codes = drop_codes,
       counts = rbind(cl$counts,
                      data.table(step = c("first positive week >= 9 with threshold (before burn-in test)",
                                          "after burn-in zero-demand rule", "launch products"),
                                 lines = c(n_first_hit, n_after_burn, n)),
                      use.names = TRUE))
}

# Eligibility: product has a launch week >= dev_first and enough weeks for k + 4 weeks
eligible_ids <- function(ctx, k, cut) {
  L <- ctx$launch$L
  which(L >= ctx$cfg$dev_first & L + k + H_MAX - 1L <= cut)
}

make_sets <- function(ctx, k) {
  cfg <- ctx$cfg
  L <- ctx$launch$L
  if (cfg$split == "time") {
    train <- which(L >= cfg$dev_first & L <= cfg$dev_last & L + k + H_MAX - 1L <= cfg$dev_last)
    train_cut <- cfg$dev_last
    test <- which(L >= cfg$test_first & L + k + H_MAX - 1L <= LAST_WEEK)
  } else {
    all_ids <- eligible_ids(ctx, k, LAST_WEEK)
    train <- all_ids[ctx$u_split[all_ids] < TRAIN_SHARE_RANDOM]
    test <- all_ids[ctx$u_split[all_ids] >= TRAIN_SHARE_RANDOM]
    train_cut <- LAST_WEEK
  }
  list(train = train, test = test, train_cut = train_cut, test_cut = LAST_WEEK)
}

# ------------------------------------------------------------------
# Component C: analog prior
# ------------------------------------------------------------------

find_analogs <- function(ctx, pid, k, K) {
  L <- ctx$launch$L
  origin <- L[pid] + k - 1L
  pool <- which(L <= L[pid] - 4L)            # analog weeks 1..k+4 all end by the origin
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

analog_curves <- function(ctx, an, nsteps, origin) {
  L <- ctx$launch$L
  wk <- outer(L[an], 0:(nsteps - 1L), "+")
  if (any(wk > origin)) stop("analog uses a week after the origin")
  vals <- matrix(ctx$U[cbind(rep(an, nsteps), as.vector(wk))], nrow = length(an))
  list(log = colMeans(log1p(vals)), raw = colMeans(vals))
}

global_curves <- function(ctx, ids, cut) {
  L <- ctx$launch$L
  lg <- rep(NA_real_, GLOBAL_STEPS); lr <- rep(NA_real_, GLOBAL_STEPS)
  for (s in seq_len(GLOBAL_STEPS)) {
    sel <- ids[L[ids] + s - 1L <= cut]
    if (length(sel)) {
      v <- ctx$U[cbind(sel, L[sel] + s - 1L)]
      lg[s] <- mean(log1p(v)); lr[s] <- mean(v)
    }
  }
  list(log = lg, raw = lr)
}

# ------------------------------------------------------------------
# Rows: one row per (product, week since launch) for a given k
# ------------------------------------------------------------------

build_rows <- function(ctx, ids, k, cut, glob, K) {
  L <- ctx$launch$L
  nsteps <- k + H_MAX
  out <- vector("list", length(ids))
  nfb <- 0L
  for (j in seq_along(ids)) {
    pid <- ids[j]
    Lp <- L[pid]
    stopifnot(Lp + nsteps - 1L <= cut)
    origin <- Lp + k - 1L
    an <- find_analogs(ctx, pid, k, K)
    if (length(an)) {
      cur <- analog_curves(ctx, an, nsteps, origin); nan <- length(an)
    } else {
      nfb <- nfb + 1L
      cur <- list(log = glob$log[seq_len(nsteps)], raw = glob$raw[seq_len(nsteps)]); nan <- 0L
    }
    wk <- Lp + 0:(nsteps - 1L)
    y <- ctx$U[pid, wk]
    s <- seq_len(nsteps)
    hist_y <- y[seq_len(k)]
    doy <- as.integer(format(week_start_date(Lp), "%j"))
    out[[j]] <- data.table(
      pid = pid, StockCode = ctx$launch$StockCode[pid], k = k, s = s, week = wk, y = y,
      is_target = s > k, h = s - k, origin = origin,
      own_mean = mean(hist_y), own_var = if (k > 1L) var(hist_y) else NA_real_,
      log1p_own = log1p(mean(hist_y)), last = y[k],
      log_s = log(s), log_lp = ctx$LP[pid, origin],
      sin_s = sin(2 * pi * (doy - 1) / 365.25), cos_s = cos(2 * pi * (doy - 1) / 365.25),
      analog_log = cur$log[s], analog_raw = cur$raw[s], n_analog = nan
    )
  }
  rows <- rbindlist(out)
  attr(rows, "n_fallback") <- nfb
  rows
}

# ------------------------------------------------------------------
# Models
# ------------------------------------------------------------------

design_m4 <- function(rows) cbind(1, rows$log_s, rows$analog_log, rows$log_lp, rows$sin_s, rows$cos_s)

fit_m4 <- function(rows, family = "nb", use_re = TRUE) {
  X <- design_m4(rows)
  y <- rows$y
  pidx <- as.integer(factor(rows$pid))
  P <- ncol(X)
  G <- length(Z_GRID)
  has_theta <- family == "nb"
  i_b <- seq_len(P)
  i_th <- if (has_theta) P + 1L else NA_integer_
  i_tau <- if (use_re) P + has_theta + 1L else NA_integer_
  unpack <- function(par) list(
    b = par[i_b],
    theta = if (has_theta) exp(par[i_th]) else NA_real_,
    tau = if (use_re) exp(par[i_tau]) else 0
  )
  nll <- function(par) {
    p <- unpack(par)
    eta <- as.vector(X %*% p$b)
    if (!use_re) {
      v <- -sum(logdens_lmu(y, eta, p$theta, family))
      return(if (is.finite(v)) v else 1e10)
    }
    LMU <- outer(eta, p$tau * Z_GRID, "+")
    LL <- matrix(logdens_lmu(rep(y, G), as.vector(LMU), p$theta, family), nrow = length(y))
    Rs <- rowsum(LL, pidx)
    A <- sweep(Rs, 2, LOG_W_Z, "+")
    mx <- apply(A, 1, max)
    v <- -sum(mx + log(rowSums(exp(A - mx))))
    if (is.finite(v)) v else 1e10
  }
  b0 <- coef(lm(log1p(y) ~ X[, -1]))
  b0[is.na(b0)] <- 0
  start <- c(b0, if (has_theta) log(5), if (use_re) log(0.3))
  fit <- optim(start, nll, method = "BFGS", control = list(maxit = 500, reltol = 1e-10))
  p <- unpack(fit$par)
  list(beta = p$b, theta = p$theta, tau = p$tau, family = family, use_re = use_re,
       loglik = -fit$value, convergence = fit$convergence, message = fit$message,
       n_rows = length(y), n_products = length(unique(pidx)))
}

predict_m4 <- function(fit, rows, n_draws = N_DRAWS) {
  X <- design_m4(rows)
  eta <- as.vector(X %*% fit$beta)
  pids <- unique(rows$pid)
  pidx <- match(rows$pid, pids)
  G <- length(Z_GRID)
  hist <- !rows$is_target
  pw <- exp(LOG_W_Z); pw <- pw / sum(pw)
  W <- matrix(pw, length(pids), G, byrow = TRUE)
  if (fit$use_re && fit$tau > 0) {
    LMU <- outer(eta[hist], fit$tau * Z_GRID, "+")
    LL <- matrix(logdens_lmu(rep(rows$y[hist], G), as.vector(LMU), fit$theta, fit$family), nrow = sum(hist))
    Rs <- rowsum(LL, pidx[hist])
    Rfull <- matrix(0, length(pids), G)
    Rfull[as.integer(rownames(Rs)), ] <- Rs
    A <- sweep(Rfull, 2, LOG_W_Z, "+")
    mx <- apply(A, 1, max)
    E <- exp(A - mx)
    W <- E / rowSums(E)
  }
  tgt <- which(rows$is_target)
  point <- numeric(length(tgt))
  DR <- matrix(NA_real_, length(tgt), n_draws)
  sp <- split(seq_along(tgt), pidx[tgt])
  for (j in names(sp)) {
    jj <- as.integer(j)
    ii <- sp[[j]]
    r <- tgt[ii]
    w <- W[jj, ]
    mu_grid <- exp(outer(eta[r], fit$tau * Z_GRID, "+"))
    point[ii] <- as.vector(mu_grid %*% w)
    idx <- sample.int(G, n_draws, replace = TRUE, prob = w)
    mu_draw <- exp(outer(eta[r], fit$tau * Z_GRID[idx], "+"))
    DR[ii, ] <- draw_fam(mu_draw, fit$theta, fit$family)
  }
  um <- as.numeric(W %*% Z_GRID)
  usd <- sqrt(pmax(as.numeric(W %*% (Z_GRID^2)) - um^2, 0))
  list(point = point, DR = DR, tgt = tgt, pids = pids,
       u_post_mean = um * fit$tau, u_post_sd = usd * fit$tau)
}

summ_draws <- function(DR, y, point) {
  qs <- t(apply(DR, 1, quantile, probs = c(0.1, 0.25, 0.5, 0.75, 0.9), type = 7))
  n <- ncol(DR)
  S <- t(apply(DR, 1, sort))
  ed <- rowMeans(abs(DR - y))
  w <- 2 * seq_len(n) - n - 1
  gmd <- (2 / n^2) * as.vector(S %*% w)
  data.frame(point = point, q10 = qs[, 1], q25 = qs[, 2], q50 = qs[, 3],
             q75 = qs[, 4], q90 = qs[, 5], crps = ed - 0.5 * gmd)
}

# Predict every model for the target rows of a row table.
# Returns a data.table with one row per (model, target row).
predict_all <- function(ctx, rows, fits, set_label, k) {
  cfg <- ctx$cfg
  fam <- cfg$family
  tg <- rows[is_target == TRUE]
  y <- tg$y
  out <- list()
  add <- function(model, sm, fb = NULL) {
    d <- data.table(model = model, set = set_label, k = k,
                    pid = tg$pid, StockCode = tg$StockCode, h = tg$h, week = tg$week,
                    origin = tg$origin, y = y, s = tg$s)
    d <- cbind(d, as.data.table(sm))
    d[, fb := if (is.null(fb)) FALSE else as.logical(fb)]
    d
  }
  theta_g <- fits$theta_global
  # M0 naive carry-forward
  DR0 <- draw_fam(matrix(tg$last, ncol = 1)[, rep(1, N_DRAWS), drop = FALSE], theta_g, fam)
  out$M0 <- add("M0", summ_draws(DR0, y, tg$last))
  # M1 own mean with method-of-moments negative binomial
  th_m <- ifelse(is.na(tg$own_var), theta_g,
                 ifelse(tg$own_var > tg$own_mean, pmin(pmax(tg$own_mean^2 / (tg$own_var - tg$own_mean), 0.05), 1e4), 1e4))
  DR1 <- draw_fam(matrix(tg$own_mean, ncol = 1)[, rep(1, N_DRAWS), drop = FALSE], th_m, fam)
  out$M1 <- add("M1", summ_draws(DR1, y, tg$own_mean), is.na(tg$own_var))
  # M2 per-series intercept-only negative binomial (own weeks only)
  hist <- rows[is_target == FALSE]
  hl <- split(hist$y, hist$pid)
  own_mean_p <- vapply(hl, mean, numeric(1))
  theta_p <- vapply(hl, function(yy) {
    if (fam != "nb") return(Inf)
    if (length(yy) <= 2L || var(yy) == 0) return(NA_real_)
    if (var(yy) <= mean(yy)) return(1e4)          # no overdispersion: Poisson-like
    th <- tryCatch(theta.ml(yy, mean(yy), limit = 50), error = function(e) NA_real_)
    if (is.finite(th)) min(max(th, 0.05), 1e4) else NA_real_
  }, numeric(1))
  m2_mean <- own_mean_p[as.character(tg$pid)]
  m2_th <- theta_p[as.character(tg$pid)]
  th2 <- ifelse(is.na(m2_th), theta_g, m2_th)
  fb2 <- is.na(m2_th)
  DR2 <- draw_fam(matrix(m2_mean, ncol = 1)[, rep(1, N_DRAWS), drop = FALSE], th2, fam)
  out$M2 <- add("M2", summ_draws(DR2, y, m2_mean), fb2)
  # M3 global negative binomial GLM (complete pooling), fitted on pooled dev target rows
  mu3 <- as.numeric(predict(fits$m3, newdata = tg, type = "response"))
  DR3 <- draw_fam(matrix(mu3, ncol = 1)[, rep(1, N_DRAWS), drop = FALSE], theta_g, fam)
  out$M3 <- add("M3", summ_draws(DR3, y, mu3))
  # M5 analog-only prior (no product data)
  DR5 <- draw_fam(matrix(tg$analog_raw, ncol = 1)[, rep(1, N_DRAWS), drop = FALSE], theta_g, fam)
  out$M5 <- add("M5", summ_draws(DR5, y, tg$analog_raw), tg$n_analog == 0)
  # M5g global average curve at the same weeks since launch (F2 baseline)
  g_raw <- fits$glob_raw[tg$s]
  DR5g <- draw_fam(matrix(g_raw, ncol = 1)[, rep(1, N_DRAWS), drop = FALSE], theta_g, fam)
  out$M5g <- add("M5g", summ_draws(DR5g, y, g_raw))
  # M4 partial pooling, empirical Bayes random intercept (fitted on this k's train rows)
  if (!is.null(fits$m4)) {
    pr <- predict_m4(fits$m4, rows, N_DRAWS)
    sm <- summ_draws(pr$DR, y, pr$point)
    out$M4 <- add("M4", sm)
  }
  rbindlist(out, fill = TRUE)
}

# ------------------------------------------------------------------
# Pipeline driver
# ------------------------------------------------------------------

# Build train rows for every k, and fit the pooled global GLM (M3) once across k.
prepare_pooled <- function(ctx, ks, K) {
  cfg <- ctx$cfg
  rows_by_k <- list(); globs <- list(); nfb_train <- integer(0)
  for (k in ks) {
    sets <- make_sets(ctx, k)
    glob <- global_curves(ctx, sets$train, sets$train_cut)
    tr <- build_rows(ctx, sets$train, k, sets$train_cut, glob, K)
    stopifnot(max(tr$week) <= sets$train_cut)
    rows_by_k[[as.character(k)]] <- tr
    globs[[as.character(k)]] <- glob
    nfb_train[as.character(k)] <- attr(tr, "n_fallback")
  }
  pooled <- rbindlist(lapply(ks, function(k) {
    r <- rows_by_k[[as.character(k)]]
    r[is_target == TRUE, .(y, k = k, h, log1p_own, log_lp, sin_s, cos_s)]
  }))
  f3 <- y ~ log1p_own + k + h + log_lp + sin_s + cos_s
  if (cfg$family == "nb") {
    m3 <- glm.nb(f3, data = pooled, control = glm.control(maxit = 100))
    theta_g <- m3$theta
  } else {
    m3 <- glm(f3, data = pooled, family = poisson())
    theta_g <- Inf
  }
  list(rows = rows_by_k, globs = globs, m3 = m3, theta_global = theta_g,
       nfb_train = nfb_train, n_m3_rows = nrow(pooled))
}

run_k <- function(ctx, k, pre, K) {
  cfg <- ctx$cfg
  set.seed(cfg$seed + k)
  sets <- make_sets(ctx, k)
  tr <- pre$rows[[as.character(k)]]
  glob <- pre$globs[[as.character(k)]]
  fit4 <- fit_m4(tr, family = cfg$family, use_re = TRUE)
  fit4_null <- fit_m4(tr, family = cfg$family, use_re = FALSE)
  lrt_stat <- max(0, 2 * (fit4$loglik - fit4_null$loglik))
  fits <- list(m3 = pre$m3, theta_global = pre$theta_global, m4 = fit4, glob_raw = glob$raw)
  te <- build_rows(ctx, sets$test, k, sets$test_cut, glob, K)
  stopifnot(max(te$week) <= LAST_WEEK)
  p_tr <- predict_all(ctx, tr, fits, "train", k)
  p_te <- predict_all(ctx, te, fits, "test", k)
  list(pred = rbind(p_tr, p_te), fit4 = fit4,
       info = data.table(k = k, n_train_products = length(sets$train), n_test_products = length(sets$test),
                         train_cut = sets$train_cut,
                         max_train_week = max(tr$week), max_test_week = max(te$week),
                         fb_analog_train = attr(tr, "n_fallback"), fb_analog_test = attr(te, "n_fallback"),
                         tau = fit4$tau, theta_m4 = fit4$theta, m4_convergence = fit4$convergence,
                         m4_loglik = fit4$loglik, m4_null_loglik = fit4_null$loglik,
                         lrt_stat = lrt_stat, lrt_p_boundary = 0.5 * pchisq(lrt_stat, df = 1, lower.tail = FALSE),
                         m4_null_convergence = fit4_null$convergence))
}

run_pipeline <- function(cfg = CFG_DEFAULT, ks = K_GRID, K = cfg$K, ks_eval = ks) {
  set.seed(cfg$seed)
  ctx <- prepare_context(cfg)
  pre <- prepare_pooled(ctx, K_GRID, K)     # M3 is always pooled over the full k grid
  preds <- list(); fits <- list(); infos <- list()
  for (k in ks_eval) {
    r <- run_k(ctx, k, pre, K)
    preds[[as.character(k)]] <- r$pred
    fits[[as.character(k)]] <- r$fit4
    infos[[as.character(k)]] <- r$info
    message("k=", k, " done")
  }
  list(cfg = cfg, K = K, counts = ctx$counts, preds = rbindlist(preds), fits = fits,
       info = rbindlist(infos), m3_coef = coef(pre$m3), m3_theta = pre$theta_global,
       m3_rows = pre$n_m3_rows, ctx_launch = ctx$launch[, .(pid, StockCode, L, qtr)],
       ctx = ctx)
}
