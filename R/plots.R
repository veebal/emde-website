# ---------------------------------------------------------------------------
# plots.R : shared theme, branding and plot builders used by every page. All inputs are
# data frames read from data/err.sqlite (see R/db.R); nothing here computes a statistic.
# `logo` is a path to the XKDR logo *relative to the page being rendered*.
# ---------------------------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a
emde_font <- "Latin Modern Roman"
# Categorical palette (validated for adjacent-pair colour-vision separation): one slot per basket currency
tol_bright <- c(USD = "#2a78d6", JPY = "#eb6834", EUR = "#1baf7a", GBP = "#eda100", "#e87ba4", "#008300", "#6250d6")
# Status palette (validated all-pairs; labels always accompany the colour)
status_cols <- c("New regime" = "#e34948", "Variance change" = "#6250d6", "Change likely" = "#eda100", "Stable" = "#1baf7a", "Data ended" = "#9a9a9a", "Not available" = "#d0d0d0")
status_badge <- function(st) {
  cls <- c("New regime" = "status-new", "Variance change" = "status-variance", "Change likely" = "status-likely", "Stable" = "status-stable", "Data ended" = "status-ended", "Not available" = "status-na")[st]
  sprintf('<span class="status-badge %s">%s</span>', ifelse(is.na(cls), "status-na", cls), st)
}
regressor_cols <- c(USD = "b_usd", JPY = "b_jpy", EUR = "b_eur", GBP = "b_gbp")
online_beta_cols <- c(USD = "beta_usd", JPY = "beta_jpy", EUR = "beta_eur", GBP = "beta_gbp")

xkdr_theme <- function(base_size = 10) {
  ggplot2::theme_bw(base_family = emde_font, base_size = base_size) +
    ggplot2::theme(
      panel.grid.major.x = ggplot2::element_blank(),
      panel.grid.major.y = ggplot2::element_line(colour = "grey92", linewidth = 0.25),
      panel.grid.minor   = ggplot2::element_blank(),
      panel.border       = ggplot2::element_blank(),
      axis.line          = ggplot2::element_line(colour = "black", linewidth = 0.5),
      axis.ticks.length  = ggplot2::unit(0.15, "cm"),
      axis.ticks         = ggplot2::element_line(color = "black", linewidth = 0.5),
      axis.text.x        = ggplot2::element_text(size = base_size, color = "black", margin = ggplot2::margin(t = 7)),
      axis.text.y        = ggplot2::element_text(size = base_size, color = "black", margin = ggplot2::margin(r = 7)),
      axis.title.y       = ggplot2::element_text(size = base_size, color = "black", margin = ggplot2::margin(r = 6)),
      plot.margin        = ggplot2::margin(t = 6, r = 8, b = 6, l = 6, unit = "pt"),
      legend.background  = ggplot2::element_blank(),
      legend.key         = ggplot2::element_blank(),
      legend.text        = ggplot2::element_text(size = base_size - 2, color = "black")
    )
}

add_xkdr_branding <- function(ply_obj, logo) {
  logo_uri <- knitr::image_uri(logo)
  ply_obj |>
    plotly::layout(
      images = list(list(source = logo_uri, xref = "paper", yref = "paper", x = 0.98, y = -0.03, sizex = 0.075, sizey = 0.075,
                         xanchor = "right", yanchor = "top", opacity = 1)),
      annotations = list(list(x = 1, y = -0.12, text = "Source: XKDR Forum", showarrow = FALSE, xref = "paper", yref = "paper",
                              xanchor = "right", yanchor = "top", font = list(size = 14, color = "#6c757d", family = emde_font)))
    ) |>
    plotly::config(displaylogo = FALSE)
}

# --- Country page: level of the exchange rate with break dates ---------------
# level: data.frame(date, rate); bd: Date vector of dated breaks
plot_level <- function(level, bd, label, logo) {
  df <- level
  p <- ggplot2::ggplot(df, ggplot2::aes(x = date, y = rate)) +
    ggplot2::geom_line(linewidth = 2 / ggplot2::.pt, color = "#EE6677") +
    ggplot2::geom_vline(xintercept = as.numeric(bd), color = "grey50", linetype = "dashed", linewidth = 0.5) +
    ggplot2::labs(x = NULL, y = label) +
    xkdr_theme(16) +
    ggplot2::scale_y_continuous(labels = scales::label_comma(), expand = ggplot2::expansion(mult = c(0.04, 0.04)))
  ply <- plotly::ggplotly(p, tooltip = c("x", "y"))
  if (length(bd) > 0 && !any(is.na(bd))) {
    med <- stats::median(df$rate, na.rm = TRUE)
    for (b in bd) {
      idx  <- which.min(abs(as.numeric(df$date) - b))
      high <- df$rate[idx] > med
      ply <- plotly::add_annotations(ply, x = b, y = if (high) 0.02 else 0.98, xref = "x", yref = "paper",
        text = format(as.Date(b, origin = "1970-01-01"), "%Y-%m"), showarrow = FALSE, textangle = -90, xanchor = "right",
        yanchor = if (high) "bottom" else "top", font = list(color = "grey50", size = 16, family = emde_font))
    }
  }
  add_xkdr_branding(ply, logo)
}

# --- Country page: the dated-regime table in the layout of the former fit (regime, n_obs, r2, coefficients)
regimes_display <- function(reg, regs) {
  out <- data.frame(regime = sprintf("%s--%s", format(reg$start_date), format(reg$end_date)), n_obs = reg$n_obs, r2 = reg$r2,
                    `(Intercept)` = reg$b_intercept, check.names = FALSE)
  for (r in regs) out[[r]] <- reg[[regressor_cols[[r]]]]
  out$`(Variance)` <- reg$variance
  out
}

# --- Landing page: R-squared timeline, one row per country (ISO3) ------------
# regimes: regimes_all(); order: ISO3 codes top to bottom; events: data.frame(label, date)
plot_timeline <- function(regimes, order, events, logo) {
  n <- length(order)
  d <- regimes |>
    dplyr::filter(iso3 %in% order) |>
    dplyr::arrange(iso3, start_date) |>
    dplyr::group_by(iso3) |>
    dplyr::mutate(xmax = dplyr::lead(start_date, default = dplyr::last(end_date))) |>
    dplyr::ungroup() |>
    dplyr::mutate(row = match(iso3, order), ymin = n - row + 0.06, ymax = n - row + 0.94,
                  text = sprintf("%s (%s)<br>%s to %s<br>R² = %s", country, iso3, format(start_date), format(end_date),
                                 ifelse(is.na(r2), "n/a", sprintf("%.2f", r2))))
  pal <- c("white", "#d9d6f7", "#9a9be3", "#3a6fb5", "#1d2f66", "#150b34")
  p <- ggplot2::ggplot(d) +
    ggplot2::geom_rect(ggplot2::aes(xmin = start_date, xmax = xmax, ymin = ymin, ymax = ymax, fill = r2, text = text)) +
    ggplot2::scale_fill_gradientn(colours = pal, limits = c(0, 1), name = "R²", na.value = "grey85") +
    ggplot2::scale_y_continuous(breaks = n - seq_len(n) + 0.5, labels = order, expand = c(0, 0)) +
    ggplot2::scale_x_date(expand = c(0, 0), date_breaks = "5 years", date_labels = "%Y") +
    ggplot2::labs(x = NULL, y = NULL, title = "Emerging Markets: R² Timeline") +
    xkdr_theme(10) +
    ggplot2::theme(panel.grid.major.y = ggplot2::element_blank(), axis.ticks.length.y = ggplot2::unit(0, "cm"))
  if (!is.null(events) && nrow(events) > 0) {
    p <- p +
      ggplot2::geom_vline(data = events, ggplot2::aes(xintercept = as.numeric(date), colour = label), linetype = "dashed", linewidth = 0.5) +
      ggplot2::scale_colour_manual(values = rep(unname(tol_bright), length.out = nrow(events)), name = NULL)
  }
  plotly::ggplotly(p, tooltip = "text", height = max(600, 16 * n + 160)) |>
    plotly::layout(margin = list(b = 190), legend = list(orientation = "h", x = 0, xanchor = "left", y = -0.17, yanchor = "top")) |>
    add_xkdr_branding(logo)
}

# --- Home page: world map of statuses ------------------------------------------
# status: status_all(); k: the alert horizon
plot_map <- function(status, k, logo) {
  st <- status; st$status <- factor(st$status, levels = names(status_cols))
  st$text <- sprintf("<b>%s</b> (%s)<br>Status: %s<br>Regime since: %s<br>USD weight: %s<br>P(change in last %s weeks): %s",
                     st$country, st$ccy, st$status, ifelse(is.na(st$regime_since), "n/a", format(st$regime_since)),
                     ifelse(is.na(st$usd_weight), "n/a", sprintf("%.2f", st$usd_weight)), k,
                     ifelse(is.na(st$p_change_26), "n/a", sprintf("%.2f", st$p_change_26)))
  st$href <- sprintf("countries/%s/index.html", st$iso3)
  g <- list(showframe = FALSE, showcoastlines = TRUE, coastlinecolor = "#d0d0d0", projection = list(type = "natural earth"),
            showland = TRUE, landcolor = "#f3f3f1", showocean = TRUE, oceancolor = "#ffffff", showcountries = TRUE,
            countrycolor = "#e0e0e0", bgcolor = "rgba(0,0,0,0)", lataxis = list(range = c(-45, 60)))
  p <- plotly::plot_geo(height = 520)
  for (lv in levels(st$status)) {
    d <- st[st$status == lv, ]; if (!nrow(d)) next
    p <- plotly::add_trace(p, type = "choropleth", locations = d$iso3, locationmode = "ISO-3",
                           z = rep(1, nrow(d)), colorscale = list(list(0, status_cols[[lv]]), list(1, status_cols[[lv]])),
                           showscale = FALSE, text = d$text, hoverinfo = "text", customdata = d$href, name = lv,
                           marker = list(line = list(color = "#ffffff", width = 0.6)), zmin = 0, zmax = 1)
  }
  p <- plotly::layout(p, geo = g, margin = list(l = 0, r = 0, t = 0, b = 0), paper_bgcolor = "rgba(0,0,0,0)", font = list(family = emde_font)) |>
    plotly::config(displaylogo = FALSE, modeBarButtonsToRemove = c("select2d", "lasso2d"))
  htmlwidgets::onRender(p, "function(el) { el.on('plotly_click', function(d) { var h = d.points[0].customdata; if (h) window.location = h; }); }")
}

map_legend <- function() {
  paste0('<div class="status-legend">',
         paste(sprintf('<span class="status-badge %s">%s</span>', c("status-new", "status-variance", "status-likely", "status-stable", "status-ended"),
                       c("New regime: a probability alert fired within the last 26 weeks", "Variance change: only a variance alert fired within the last 26 weeks", "Change likely: probability above the threshold, alert not yet confirmed", "Stable", "Data ended: the published series stops more than a year ago")), collapse = ""),
         '</div>')
}

# --- Home page: status table ---------------------------------------------------
status_table <- function(st, k) {
  st <- st[order(factor(st$status, levels = names(status_cols)), -st$p_change_26, na.last = TRUE), ]
  out <- data.frame(
    Country = sprintf('<a href="countries/%s/index.html">%s</a>', st$iso3, st$country), Currency = st$ccy,
    Status = status_badge(st$status), `Regime since` = ifelse(is.na(st$regime_since), "", format(st$regime_since)),
    `USD weight` = ifelse(is.na(st$usd_weight), "", sprintf("%.2f", st$usd_weight)),
    `R²` = ifelse(is.na(st$r2), "", sprintf("%.2f", st$r2)),
    `P(change)` = ifelse(is.na(st$p_change_26), "", sprintf("%.2f", st$p_change_26)),
    `Last alert` = ifelse(is.na(st$last_prob_alert_date), "", format(st$last_prob_alert_date)),
    `Last variance alert` = ifelse(is.na(st$last_var_alert_date), "", paste(format(st$last_var_alert_date), st$last_var_direction)), check.names = FALSE)
  names(out)[names(out) == "P(change)"] <- sprintf("P(change, %d wks)", k)
  knitr::kable(out, format = "html", escape = FALSE, table.attr = 'class="table table-striped table-hover table-sm"')
}

# --- Alerts and revisions tables ------------------------------------------------
alerts_table <- function(a, with_country = TRUE) {
  if (is.null(a) || !nrow(a)) { cat("No alerts on record.\n"); return(invisible(NULL)) }
  isv <- a$rule == "variance"
  out <- data.frame(Date = format(a$date), Rule = a$rule,
                    Direction = ifelse(isv, ifelse(a$direction == "fall", "fall (band narrowed)", "rise (band widened)"), ""),
                    `Probable start of the new regime` = ifelse(isv, paste("within the", a$k, "weeks from", format(a$claimed_start)), format(a$claimed_start)),
                    Probability = ifelse(isv, "", sprintf("%.3f", a$p)), check.names = FALSE)
  if (with_country) out <- cbind(Country = sprintf('<a href="countries/%s/index.html">%s</a>', a$iso3, a$iso3), Currency = a$ccy, out)
  cat(knitr::kable(out, format = "html", escape = FALSE, table.attr = 'class="table table-striped table-hover table-sm"'))
}
revisions_table <- function(r, with_country = TRUE) {
  if (is.null(r) || !nrow(r)) { cat("No revisions on record: this is the first build, or nothing has changed since the previous one.\n"); return(invisible(NULL)) }
  out <- data.frame(Build = r$build_date, Change = r$kind, Before = r$old_value, After = r$new_value, check.names = FALSE)
  if (with_country) out <- cbind(Country = sprintf('<a href="countries/%s/index.html">%s</a>', r$iso3, r$iso3), Currency = r$ccy, out)
  cat(knitr::kable(out, format = "html", escape = FALSE, table.attr = 'class="table table-striped table-hover table-sm"'))
}

# --- Country page: status sentence, probability chart, weights with the filter ---
# st: one row of status_all(); alerts: alerts_ccy()
status_text <- function(st, alerts, bc) {
  if (!nrow(st) || st$status == "Not available") return("The online filter is not available for this currency.")
  if (st$status == "Data ended") return(sprintf("%s The published series for this currency ends on %s; the results below stop there.", status_badge(st$status), format(st$last_obs)))
  k <- bc$alert$k
  base <- sprintf("%s The dated regime in force began on %s. On %s the probability that a new regime began within the previous %d weeks was %.2f",
                  status_badge(st$status), format(st$regime_since), format(st$last_obs), k, st$p_change_26)
  if (!is.na(st$last_prob_alert_date)) {
    pa <- alerts[alerts$rule == "probability", ]
    base <- paste0(base, sprintf("; the latest probability alert fired on %s, with %s as the most probable start of the new regime",
                                 format(st$last_prob_alert_date), format(pa$claimed_start[which.max(pa$date)])))
  }
  if (!is.na(st$last_var_alert_date))
    base <- paste0(base, sprintf("; the latest variance alert fired on %s, when the residual variance %s", format(st$last_var_alert_date),
                                 if (identical(st$last_var_direction, "fall")) "fell and the band narrowed" else "rose and the band widened"))
  paste0(base, ".")
}

probability_text <- function(onl, bc) {
  if (is.null(onl) || !nrow(onl)) return("Not available.")
  ac <- bc$alert
  sprintf(paste("Each week the filter updates the posterior distribution of the time since the last change in the basket weights or the residual variance, using only the data up to that week.",
                "The line is the probability that the current regime is younger than %d weeks. An alert (marker) fires at the first week of a spell of %d consecutive weeks with this probability at or above %.2f, at most once every %d weeks.",
                "The dashed lines are the breaks dated with the whole sample, for comparison; the filter does not use them."),
          ac$k, ac$persist, ac$threshold, ac$refractory)
}

# onl: online_ccy(); alerts: alerts_ccy(); bd: dated breaks
plot_probability <- function(onl, alerts, bd, bc, logo) {
  k <- bc$alert$k; pk <- paste0("p_change_", k)
  df <- data.frame(date = onl$date, p = onl[[pk]])
  p <- ggplot2::ggplot(df, ggplot2::aes(x = date, y = p)) +
    ggplot2::geom_hline(yintercept = bc$alert$threshold, colour = "grey70", linewidth = 0.4) +
    ggplot2::geom_vline(xintercept = as.numeric(bd), colour = "grey50", linetype = "dashed", linewidth = 0.4) +
    ggplot2::geom_line(linewidth = 2 / ggplot2::.pt, colour = "#2a78d6") +
    ggplot2::labs(x = NULL, y = sprintf("P(regime younger than %d weeks)", k)) +
    ggplot2::scale_y_continuous(limits = c(0, 1), expand = ggplot2::expansion(mult = c(0.02, 0.04))) +
    xkdr_theme(16)
  a <- alerts[alerts$rule == "probability", ]
  if (nrow(a)) {
    ad <- data.frame(date = a$date, p = a$p, label = sprintf("Alert %s<br>probable start %s", format(a$date), format(a$claimed_start)))
    p <- p + ggplot2::geom_point(data = ad, ggplot2::aes(x = date, y = p, text = label), colour = "#e34948", size = 2.6, shape = 21, fill = "white", stroke = 1.2)
  }
  plotly::ggplotly(p, tooltip = c("x", "y", "text")) |> add_xkdr_branding(logo)
}

# reg: regimes_ccy(); onl: online_ccy() or NULL; regs: the basket currencies of this country
plot_weights_online <- function(reg, onl, regs, logo) {
  w <- do.call(rbind, lapply(regs, function(r) {
    # the step function: each regime's weight at its start and at its end
    d <- data.frame(date = c(reg$start_date, reg$end_date), Currency = r, Weight = rep(reg[[regressor_cols[[r]]]], 2), source = "dated regimes")
    d[order(d$date), ]
  }))
  if (!is.null(onl) && nrow(onl)) {
    o <- do.call(rbind, lapply(regs, function(r) data.frame(date = onl$date, Currency = r, Weight = onl[[online_beta_cols[[r]]]], source = "online filter")))
    w <- rbind(w, o)
  }
  p <- ggplot2::ggplot(w, ggplot2::aes(x = date, y = Weight, colour = Currency, linetype = source)) +
    ggplot2::geom_line(linewidth = 2 / ggplot2::.pt, alpha = 0.95) +
    ggplot2::scale_colour_manual(values = tol_bright[regs]) +
    ggplot2::scale_linetype_manual(values = c("dated regimes" = "solid", "online filter" = "dotted")) +
    ggplot2::labs(x = NULL, y = "Basket weight", colour = NULL, linetype = NULL) +
    xkdr_theme(16) +
    ggplot2::scale_y_continuous(labels = scales::label_comma(), expand = ggplot2::expansion(mult = c(0.04, 0.04)))
  ply <- plotly::ggplotly(p, tooltip = c("x", "y", "Currency", "source"))
  for (i in seq_along(ply$x$data)) {
    nm <- ply$x$data[[i]]$name
    if (!is.null(nm)) ply$x$data[[i]]$name <- gsub("^\\((.*),(.*)\\)$", "\\1, \\2", nm)
  }
  add_xkdr_branding(ply, logo)
}

# --- Country page: variance CUSUM panel --------------------------------------------
variance_text <- function(onl, bc) {
  if (is.null(onl) || !nrow(onl) || is.null(onl$var_down)) return("Not available.")
  vs <- bc$variance
  sprintf(paste("A second detector watches the width of the band. Each week the squared one-step residual, standardised by the filter's own coefficients, is compared with the median squared residual of the preceding %d weeks (divided by %.4f so that it estimates the variance).",
                "Two CUSUM statistics accumulate the evidence for a fall of the variance to a %s of its reference value and for a rise to %s times it. An alert (marker) fires when either crosses the horizontal line at %.2f, the logarithm of %s, after which both statistics restart; at most one alert every %d weeks.",
                "A variance alert claims that the change lies within the previous %d weeks."),
          as.integer(vs$window), 0.4549, if (abs(vs$rho - 3) < 1e-8) "third" else sprintf("1/%s", format(vs$rho)), format(vs$rho),
          log(1 / vs$alpha), format(round(1 / vs$alpha)), as.integer(bc$alert$refractory), as.integer(vs$claim))
}

plot_variance <- function(onl, alerts, bc, logo) {
  vs <- bc$variance; h <- log(1 / vs$alpha)
  df <- rbind(data.frame(date = onl$date, value = onl$var_down, statistic = "fall (band narrowing)"),
              data.frame(date = onl$date, value = onl$var_up, statistic = "rise (band widening)"))
  p <- ggplot2::ggplot(df, ggplot2::aes(x = date, y = value, colour = statistic)) +
    ggplot2::geom_hline(yintercept = h, colour = "grey70", linewidth = 0.4) +
    ggplot2::geom_line(linewidth = 2 / ggplot2::.pt) +
    ggplot2::scale_colour_manual(values = c("fall (band narrowing)" = "#1baf7a", "rise (band widening)" = "#eb6834")) +
    ggplot2::labs(x = NULL, y = "CUSUM statistic", colour = NULL) +
    ggplot2::scale_y_continuous(expand = ggplot2::expansion(mult = c(0.02, 0.06))) +
    xkdr_theme(16)
  a <- alerts[alerts$rule == "variance", ]
  if (nrow(a)) {
    idx <- match(a$date, onl$date)
    ad <- data.frame(date = a$date, value = ifelse(a$direction == "fall", onl$var_down[idx], onl$var_up[idx]),
                     label = sprintf("Variance alert %s<br>variance %s, band %s", format(a$date),
                                     ifelse(a$direction == "fall", "fell", "rose"), ifelse(a$direction == "fall", "narrowed", "widened")))
    p <- p + ggplot2::geom_point(data = ad, ggplot2::aes(x = date, y = value, text = label), inherit.aes = FALSE,
                                 colour = "#6250d6", size = 2.8, shape = 23, fill = "white", stroke = 1.2)
  }
  plotly::ggplotly(p, tooltip = c("x", "y", "colour", "text")) |> add_xkdr_branding(logo)
}
