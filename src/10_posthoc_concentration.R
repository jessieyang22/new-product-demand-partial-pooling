# POST-HOC DESCRIPTIVE DIAGNOSTIC (added after the test results had been read; NOT pre-registered, does not change F1 to F7).
# Question: is the k = 4 WAPE of M0 and M4 driven by a few products?
# Uses only the saved k = 4 test predictions in data/interim/run_baseline.rds (written by src/03).
# Like-for-like: the excluded products are the same set for both models, chosen by M4's own error ranking.
suppressPackageStartupMessages(library(data.table))
r <- readRDS("data/interim/run_baseline.rds")
p <- r$preds[k == 4 & set == "test"]
p[, ae := abs(point - y)]
m4 <- p[model == "M4", .(abs_err = sum(ae)), by = pid][order(-abs_err)]
top1_ids <- m4$pid[1]
top5_ids <- m4$pid[1:5]
summ <- list(); byprod <- list()
for (m in c("M0", "M4")) {
  q <- p[model == m]
  bp <- q[, .(abs_err = sum(ae), units = sum(y), bias = sum(point - y)), by = pid][order(-abs_err)]
  tot <- sum(bp$abs_err); tot_units <- sum(bp$units)
  e1 <- bp[pid %in% top1_ids]; e5 <- bp[pid %in% top5_ids]
  summ[[m]] <- data.table(
    model = m, k = 4, n_products = nrow(bp),
    wape_all = tot / tot_units,
    top1_M4_error_product_share = e1$abs_err / tot,
    top5_M4_error_products_share = sum(e5$abs_err) / tot,
    wape_excl_top1_M4_product = (tot - e1$abs_err) / (tot_units - e1$units),
    wape_excl_top5_M4_products = (tot - sum(e5$abs_err)) / (tot_units - sum(e5$units))
  )
  byprod[[m]] <- bp[, model := m]
}
summ <- rbindlist(summ)
print(summ)
fwrite(summ, "results/X_posthoc_concentration_summary_k4.csv")
fwrite(rbindlist(byprod), "results/X_posthoc_concentration_by_product_k4.csv")
