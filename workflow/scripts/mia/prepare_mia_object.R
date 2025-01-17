#!/usr/local/bin/Rscript

#' Prepara mia object
#' @author rwelch2

"Prepare mia object

Usage:
prepare_mia_object.R [<mia_file>] [--asv=<asv_file> --taxa=<taxa_file> --tree=<tree_file> --meta=<meta_file>] [--asv_prefix=<prefix> --log=<logfile> --config=<config> --cores=<cores>]
prepare_mia_object.R (-h|--help)
prepare_mia_object.R --version

Options:
-h --help    show this screen
--asv=<asv_file>    ASV matrix file
--taxa=<taxa_file>    Taxa file
--tree=<tree_file>    Tree file
--meta=<meta_file>    Metadata file
--log=<logfile>    name of the log file [default: logs/filter_and_trim.log]
--config=<config>    name of the config file [default: config/config.yaml]
--cores=<cores>    number of parallel CPUs [default: 8]" -> doc

library(docopt)

my_args <- commandArgs(trailingOnly = TRUE)

arguments <- docopt::docopt(doc, args = my_args,
  version = "prepare mia file V1")

if (!interactive()) {
  log_file <- file(arguments$log, open = "wt")
  sink(log_file, type = "output")
  sink(log_file, type = "message")
}

if (interactive()) {

  arguments$asv <- "output/dada2/after_qc/asv_mat_wo_chim.qs"
  arguments$taxa <- "output/taxa/kraken/minikraken/kraken_taxatable.qs"
  arguments$tree <- "output/phylotree/newick/tree.nwk"
  arguments$meta <- "data/meta.tsv"
  arguments$asv_prefix <- "asv" # "HSD2M"

}

print(arguments)

info <- Sys.info();

message("loading packages")
library(magrittr)
library(tidyverse)
library(TreeSummarizedExperiment)
library(Biostrings)
library(BiocParallel)
library(ape)
library(mia)
library(qs)
library(scater)
library(yaml)
library(parallelDist)

stopifnot(
  file.exists(arguments$asv),
  file.exists(arguments$taxa),
  file.exists(arguments$tree),
  file.exists(arguments$meta)
)

if (!is.null(arguments$config)) stopifnot(file.exists(arguments$config))

asv <- qs::qread(arguments$asv)
taxa <- qs::qread(arguments$taxa)
tree <- ape::read.tree(arguments$tree)
meta <- readr::read_tsv(arguments$meta)

asv_sequences <- colnames(asv)
colnames(asv) <- str_c(arguments$asv_prefix, seq_along(asv_sequences),
  sep = "_")
names(asv_sequences) <- colnames(asv)
asv_sequences <- Biostrings::DNAStringSet(asv_sequences)

asv_aux <- tibble::tibble(asv = colnames(asv))


# need to fix parse_taxa to return a tibble of length 
# equal to all the sequences and not only the sequences with known information

# We may have samples that didn't make it into the 
# ASV matrix but were in the metadata file.
cdata <- meta %>%
  as.data.frame() %>%
  tibble::column_to_rownames("key")

# detect nonempty samples
nonempty = rowSums(asv) %>% .[. > 0] %>% names
asv = asv[nonempty, ]
cdata = cdata[nonempty, ]

out <- TreeSummarizedExperiment::TreeSummarizedExperiment(
  assays = list(counts = t(asv)),
  colData = cdata[rownames(asv), ], # need to make sure correct order
  rowData = asv_aux %>%
    dplyr::left_join(taxa, by = "asv") %>%
    as.data.frame() %>%
    tibble::column_to_rownames("asv"),
  rowTree = tree)

bpp <- BiocParallel::MulticoreParam(workers = as.numeric(arguments$cores))

# filter asvs
tmpnames = counts(out) %>% rowSums %>% .[. > 0] %>% names

# identify samples with fewer than N species
outct = out %>% counts 
outct[outct>0]=1
tmpsamp = colSums(outct) %>% .[.>1] %>% names

message("estimate diversity")
metrics = c("coverage","gini_simpson", "inverse_simpson",
    "log_modulo_skewness", "shannon", "fisher")
    #[tmpnames, tmpsamp 
blah <- mia::estimateDiversity(out[,tmpsamp], abund_values = "counts",
  BPPARAM = bpp)
  #BPPARAM = SerialParam(), index = metrics) #, BPPARAM = bpp)

message("estimate richness")
out <- mia::estimateRichness(out, abund_values = "counts", BPPARAM = bpp)

if (!is.null(arguments$config)) {

  config <- yaml::read_yaml(arguments$config)[["beta"]]

}

compute_mds_wrap <- function(mia, dist_name, altexp_name, ncomps) {

  message("computing beta diversity for ", dist_name)

  if (dist_name %in% c("bray", "euclidean", "hellinger", "mahalanobis",
    "manhattan", "bhjattacharyya", "canberra", "chord")) {

    mia <- scater::runMDS(
      mia, FUN = parallelDist::parDist,
      method = dist_name, threads = as.numeric(arguments$cores),
      name = altexp_name, ncomponents = ncomps, exprs_values = "counts",
      keep_dist = FALSE)

  } else if (dist_name == "fjaccard") {

    mia <- scater::runMDS(
      mia, FUN = parallelDist::parDist,
      method = "fJaccard", threads = as.numeric(arguments$cores),
      name = altexp_name, ncomponents = ncomps, exprs_values = "counts",
      keep_dist = FALSE)

  } else if (dist_name == "unifrac") {

    unifrac <- mia::calculateUniFrac(
      x = t(counts(mia)), tree = rowTree(mia),
      weighted = FALSE, normalized = FALSE, BPPARAM = bpp)

    pcoa <- stats::cmdscale(unifrac, k = ncomps)
    SingleCellExperiment::reducedDim(mia, altexp_name) <- pcoa


  } else if (dist_name == "w_unifrac") {
    unifrac <- mia::calculateUniFrac(
      x = t(counts(mia)), tree = rowTree(mia),
      weighted = TRUE, normalized = FALSE, BPPARAM = bpp)

    pcoa <- stats::cmdscale(unifrac, k = ncomps)
    SingleCellExperiment::reducedDim(mia, altexp_name) <- pcoa
  } else if (dist_name == "w_unifrac_norm") {

    unifrac <- mia::calculateUniFrac(
      x = t(counts(mia)), tree = rowTree(mia),
      weighted = TRUE, normalized = TRUE, BPPARAM = bpp)
    pcoa <- stats::cmdscale(unifrac, k = ncomps)
    SingleCellExperiment::reducedDim(mia, altexp_name) <- pcoa

  } else {
    stop(dist_name, " distance not available")
  }
  mia

}



if (!is.null(config$beta_div)) {
  for (div in config$beta_div) {
    out <- compute_mds_wrap(out, div, str_c("all_", div), config$comps)
  }
}

if (any(config$beta_group != "all")) {

  beta_group <- config$beta_group
  beta_group <- beta_group[beta_group != "all"]
  grouped <- purrr::map(beta_group,
    ~ mia::agglomerateByRank(out, rank = ., na.rm = FALSE))
  names(grouped) <- beta_group

  config$beta_div <- config$beta_div[!str_detect(config$beta_div, "unifrac")]

  for (gg in names(grouped)) {
  message(gg)
    for (div in config$beta_div) {
      grouped[[gg]] <- compute_mds_wrap(grouped[[gg]], div,
        str_c(gg, div, sep = "_"), config$comps)
    }
  }

  SingleCellExperiment::altExps(out) <- grouped
}

metadata(out)[["date_processed"]] <- Sys.Date()
metadata(out)[["sequences"]] <- asv_sequences

fs::dir_create(dirname(arguments$mia_file))
qs::qsave(out, arguments$mia_file)
message("done!")