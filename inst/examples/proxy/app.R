# Two sideview canvases in one Shiny app, driven from the server through a proxy.
# Synthetic data only. Run with: shiny::runApp(system.file("examples/proxy", package = "sideview"))
library(shiny)
library(sideview)

set.seed(7)
visits <- data.frame(
  id = 1:30,
  visit_date = as.Date("2026-01-05") + sort(sample(0:120, 30)),
  sbp = round(rnorm(30, 128, 15))
)
sites <- data.frame(
  site = c("North", "South", "East", "West"),
  beds = c(120, 80, 60, 95)
)

# The "lab feed": same columns, `drop` leaves out lab_date, `empty` has no rows.
labs_now <- function(mode = "same", n = 90) {
  if (identical(mode, "empty")) n <- 0
  labs <- data.frame(
    id = sample(visits$id, n, TRUE),
    lab_date = as.Date("2026-01-05") + sample(0:120, n, TRUE),
    test = sample(c("HbA1c", "LDL", "eGFR"), n, TRUE),
    value = round(rlnorm(n, 1.5, 0.5), 2)
  )
  if (identical(mode, "drop")) labs$lab_date <- NULL
  labs
}

controls <- div(
  style = "display:flex; flex-wrap:wrap; gap:8px; align-items:center; padding:8px 0",
  actionButton("add", "Add a card"),
  actionButton("replace", "Refresh labs"),
  actionButton("remove", "Remove added card"),
  actionButton("state", "Save / restore workspace"),
  actionButton("highlight", "Highlight labs columns"),
  radioButtons("refresh", NULL, inline = TRUE,
               c("same columns" = "same", "drop lab_date" = "drop", "no rows" = "empty"))
)

ui_body <- list(
  titlePanel("sideview: two canvases and a proxy"),
  controls,
  h4("Canvas A (driven by the buttons)"),
  sideviewUI("a", height = "520px"),
  h4("Canvas B (independent)"),
  sideviewUI("b", height = "420px"),
  h4("Code composed on canvas A"),
  verbatimTextOutput("code")
)
ui <- if (requireNamespace("bslib", quietly = TRUE)) {
  do.call(bslib::page_fillable, c(ui_body, list(fillable = FALSE)))
} else {
  do.call(fluidPage, ui_body)
}

server <- function(input, output, session) {
  px <- sideviewServer("a", cards = list(visits = visits, labs = labs_now()))
  sideviewServer("b", cards = list(sites = sites, visits = visits))

  added <- reactiveVal(character())
  saved <- NULL

  observeEvent(input$add, {
    nm <- paste0("extra", length(added()) + 1L)
    sideviewProxy("a") |> sv_add_card(head(visits, 5), nm)
    added(c(added(), nm))
  })
  observeEvent(input$replace, {
    sideviewProxy("a") |> sv_replace_card("labs", labs_now(input$refresh))
  })
  observeEvent(input$remove, {
    if (length(added())) {
      sideviewProxy("a") |> sv_remove_card(utils::tail(added(), 1))
      added(utils::head(added(), -1))
    }
  })
  observeEvent(input$state, {
    if (is.null(saved)) {
      saved <<- px$state()
      showNotification("Workspace saved; press again to restore it.")
    } else {
      sv_set_state(px, saved)
    }
  })
  observeEvent(input$highlight, {
    sv_highlight(px, "labs", c("id", "lab_date"))
  })

  output$code <- renderText(px$code())
}

shinyApp(ui, server)
