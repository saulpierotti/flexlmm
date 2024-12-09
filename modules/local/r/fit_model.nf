process FIT_MODEL {
    tag "$meta.id"
    label 'process_low'

    container 'saulpierotti-ebi/pgenlibr@sha256:0a606298c94eae8d5f6baa76aa1234fa5e7072513615d092f169029eacee5b60'

    input:
    tuple val(meta), path(mm), path(var_idx), path(null_model_fit), val(perm_seed)
    tuple val(meta2), path(pgen), path(pvar), path(psam)
    path model
    tuple val(meta3), path(model_frame)
    val use_dosage

    output:
    tuple val(meta), path("*.tsv.gwas.gz") , emit: gwas
    path "versions.yml"                    , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args       = task.ext.args ?: ''
    def prefix     = task.ext.prefix ?: "${meta.id}"
    def do_permute = perm_seed ? "TRUE" : "FALSE"
    def perm_seed  = perm_seed ?: "NULL"
    def pgenlibr_read_func = use_dosage ? "Read" : "ReadHardcalls"
    """
    #!/usr/bin/env Rscript

    l.mm <- readRDS("${mm}")
    var_idx <- readRDS("${var_idx}")
    l.null <- readRDS("${null_model_fit}")
    if (${do_permute}) set.seed(${perm_seed})
    
    pvar_table <- read.table(
        # header starts with # and comment line with ##,
        # by removing the first # I make the header visible
        text = sub("^#", "", readLines("${pvar}")), header = TRUE
    )[var_idx,]
    pvar <- pgenlibr::NewPvar("${pvar}")
    pgen <- pgenlibr::NewPgen("${pgen}", pvar = pvar)
    psam <- read.table(
        "${psam}",
        sep = "\\t",
        header = TRUE,
        comment.char = "",
        check.names = FALSE
    )
    clean_colnames <- function(n){gsub("#", "", n)}
    colnames(psam) <- clean_colnames(colnames(psam))

    model <- readRDS("${model}")
    model_frame_raw <- readRDS("${model_frame}")

    y.mm <- l.mm[["y.mm"]]
    X.mm.null <- l.mm[["X.mm"]]
    L <- l.mm[["L"]]

    ll.null <- l.null[["ll"]]
    y.mm.pred <- l.null[["y.mm.pred"]]
    e.p <- l.null[["e.p"]]
    U1 <- l.null[["U1"]]
    
    samples <- intersect(intersect(psam[["IID"]], names(y.mm)), rownames(model_frame_raw))
    pgen_order <- match(samples, psam[["IID"]])
    X.mm.null <- X.mm.null[match(samples, rownames(X.mm.null)), , drop = FALSE]
    y.mm <- y.mm[match(samples, names(y.mm))]
    L <- L[match(samples, rownames(L)), match(samples, colnames(L))]
    psam <- psam[pgen_order,]
    y.mm.pred <- y.mm.pred[match(samples, names(y.mm.pred))]
    model_frame_raw <- model_frame_raw[match(samples, rownames(model_frame_raw)),]

    stopifnot(all(!is.null(names(y.mm))))
    stopifnot(all(names(y.mm) == rownames(X.mm.null)))
    stopifnot(all(names(y.mm) == rownames(L)))
    stopifnot(all(names(y.mm) == colnames(L)))
    stopifnot(all(names(y.mm) == psam[["IID"]]))
    stopifnot(all(names(y.mm) == names(y.mm.pred)))
    stopifnot(all(names(y.mm) == rownames(model_frame_raw)))
    stopifnot(
        (
            sum(is.na(L)) +
            sum(is.na(X.mm.null)) +
            sum(is.na(y.mm)) +
            sum(is.na(psam[["IID"]])) +
            sum(is.na(y.mm.pred)) +
            sum(is.na(model_frame_raw))
        ) == 0
    )
        
    # generate synthetic phenotype by permuting the uncorrelated transformation
    # of the residuals and fit the null model
    # null model fit is not needed if not permuting because we can use the one
    # obtained in the FIT_NULL_MODEL process
    if (${do_permute}) {
        y.mm <- y.mm.pred + drop(U1 %*% sample(e.p))
        stopifnot(all(rownames(X.mm.null) == rownames(y.mm)))
        fit <- .lm.fit(x = X.mm.null, y = y.mm)
        ll.null <- stats:::logLik.lm(fit)
    }

    outname <- "${prefix}.tsv.gwas.gz"
    out_con <- gzfile(outname, "w")
    header <- "chr\\tpos\\tid\\tref\\talt\\tlrt_chisq\\tlrt_df\\tpval"
    writeLines(header, out_con)

    buf <- pgenlibr::Buf(pgen)

    nvars <- length(var_idx)
    pb <- txtProgressBar(1, nvars, style = 3)
    for (i in seq_along(var_idx)) {
        setTxtProgressBar(pb, i)
        the_var_idx <- var_idx[[i]]
        pgenlibr::${pgenlibr_read_func}(pgen, buf, the_var_idx)
        model_frame_raw[["x"]] <- buf[pgen_order]
        # needed to recompute expressions such as I(x == 1)
        model_frame <- model.frame(model[-2], data = model_frame_raw)
        X <- model.matrix(model[-2], data = model_frame)
        X.mm <- forwardsolve(L, X)
        colnames(X.mm) <- colnames(X)
        rownames(X.mm) <- rownames(X)

        id <- pgenlibr::GetVariantId(pvar, the_var_idx)
        chr <- pvar_table[i, "CHROM"]
        pos <- pvar_table[i, "POS"]
        ref <- pvar_table[i, "REF"]
        alt <- pvar_table[i, "ALT"]

        stopifnot(all(rownames(X.mm) == rownames(y.mm)))
        fit <- .lm.fit(x = X.mm, y = y.mm)
        ll <- stats:::logLik.lm(fit)
        lrt_df <- attributes(ll)[["df"]] - attributes(ll.null)[["df"]]
        lrt_chisq <- 2 * as.numeric(ll - ll.null)
        pval <- (
            if (lrt_df > 0) pchisq(lrt_chisq, df = lrt_df, lower.tail = FALSE) else NA
        )

        lineout <- sprintf(
            "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s",
            chr,
            pos,
            id,
            ref,
            alt,
            lrt_chisq,
            lrt_df,
            pval
        )
        writeLines(lineout, out_con)
    }

    pgenlibr::ClosePgen(pgen)
    close(out_con)
    close(pb)

    # to make sure that the output has been written properly
    gwas <- read.table(outname, header = TRUE, sep = "\t")
    stopifnot(nrow(gwas) == nvars)
    stopifnot(ncol(gwas) == 8)

    ver_r <- strsplit(as.character(R.version["version.string"]), " ")[[1]][3]
    ver_pgenlibr <- utils::packageVersion("pgenlibr")
    system(
        paste(
            "cat <<-END_VERSIONS > versions.yml",
            "\\"${task.process}\\":",
            sprintf("    r-base: %s", ver_r),
            sprintf("    pgenlibr: %s", ver_pgenlibr),
            "END_VERSIONS\\n",
            sep = "\\n"
        )
    )
    """

    stub:
    def args        = task.ext.args ?: ''
    def prefix      = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}.tsv.gwas.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        r-base: \$(Rscript -e "cat(strsplit(as.character(R.version[\\"version.string\\"]), \\" \\")[[1]][3])")
        pgenlibr: \$(Rscript -e "cat(as.character(utils::packageVersion(\\"pgenlibr\\")))")
    END_VERSIONS
    """
}
