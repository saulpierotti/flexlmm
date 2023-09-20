// checks that the models are nested and that the correct terms are used where required
process FIT_MODEL {
    tag "$meta.id"
    label 'process_low'

    container 'saulpierotti-ebi/pgenlibr@sha256:0a606298c94eae8d5f6baa76aa1234fa5e7072513615d092f169029eacee5b60'

    input:
    tuple val(meta), path(y), path(C), path(L), path(gxe_frame), path(perm_group), path(pgen), path(psam), path(pvar), val(perm_seed)
    path fixed_effects_formula
    path model_formula
    path null_model_formula

    output:
    tuple val(meta), path("*.gwas.tsv.gz") , emit: gwas

    path "versions.yml"                    , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args       = task.ext.args ?: ''
    def prefix     = task.ext.prefix ?: "${meta.id}"
    def do_permute = perm_seed ? "TRUE" : "FALSE"
    def perm_seed  = perm_seed ?: "NULL"
    """
    #!/usr/bin/env Rscript

    y <- readRDS("${y}")
    C <- readRDS("${C}")
    L <- readRDS("${L}")
    gxe_frame <- readRDS("${gxe_frame}")
    perm_group <- readRDS("${perm_group}")

    fixed_effects_formula <- readRDS("${fixed_effects_formula}")
    model_formula         <- readRDS("${model_formula}")
    null_model_formula    <- readRDS("${null_model_formula}")

    psam <- read.table(
        "${psam}",
        sep = "\\t",
        header = TRUE,
        comment.char = "",
        check.names = FALSE
    )
    clean_colnames <- function(n){gsub("#", "", n)}
    colnames(psam) <- clean_colnames(colnames(psam))

    stopifnot(all(!is.null(names(y))))
    stopifnot(all(names(y) == rownames(C)))
    stopifnot(all(names(y) == rownames(L)))
    stopifnot(all(names(y) == colnames(L)))
    stopifnot(all(names(y) == rownames(gxe_frame)))
    stopifnot(all(names(y) == psam[["IID"]]))
    stopifnot(all(names(y) == names(perm_group)))
    stopifnot(
        sum(is.na(L)) + sum(is.na(C)) + sum(is.na(y)) + sum(is.na(gxe_frame)) + sum(is.na(perm_group)) == 0
    )

    if ( ${do_permute} ) {
        set.seed(${perm_seed})
        gt_order <- 1:length(y)
        for ( curr_group in unique(perm_group) ) {
            gt_order[perm_group == curr_group] <- sample(
                gt_order[perm_group == curr_group], replace = FALSE
            )
        }
        set.seed(NULL)
    }

    pvar <- pgenlibr::NewPvar("${pvar}")
    pgen <- pgenlibr::NewPgen("${pgen}", pvar = pvar)
    x    <- pgenlibr::Buf(pgen)

    fit_null <- lm(null_model_formula)
    ll_null  <- logLik(fit_null)

    out_con <- gzfile("${prefix}.gwas.tsv.gz", "w")
    header <- "chr\\tpos\\tid\\tref\\talt\\tlrt_chisq\\tlrt_df\\tlrt_p\\tbeta"
    writeLines(header, out_con)
    nvars <- pgenlibr::GetVariantCt(pgen)
    pb <- txtProgressBar(1, nvars, style = 3)

    for (i in 1:nvars) {
        setTxtProgressBar(pb, i)

        pgenlibr::ReadHardcalls(pgen, x, i)
        X <- model.matrix(fixed_effects_formula, data=gxe_frame)
        # drop the intercept since it is already in C, cannot drop before model.matrix so
        # that contrast are calculated correctly
        X <- subset(X, select = -`(Intercept)`)
        X_names <- colnames(X)
        X <- forwardsolve(L, X)

        if ( ${do_permute} ) X <- as.matrix(X[gt_order,])
        colnames(X) <- X_names

        var_id <- pgenlibr::GetVariantId(pvar, i)
        var_info <- strsplit(var_id, '_')[[1]]
        chr <- var_info[[1]]
        pos <- var_info[[2]]
        ref <- var_info[[3]]
        alt <- var_info[[4]]

        fit <- lm(model_formula)
        varnames <- names(coef(fit))
        # in case of single column the colname is not reported
        varnames[varnames == "X"] <- colnames(X)
        varnames[varnames == "C"] <- colnames(C)
        # remove leading X and C
        varnames <- gsub("^[X,C]", "", varnames)
        beta <- paste(varnames, coef(fit), collapse = ",", sep = "~")
        ll_fit <- logLik(fit)
        lrt_df <- attributes(ll_fit)[["df"]] - attributes(ll_null)[["df"]]
        lrt_chisq <- 2 * as.numeric(ll_fit - ll_null)
        p_lrt <- pchisq(lrt_chisq, df = lrt_df, lower.tail = FALSE)

        lineout <- sprintf(
            "%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s",
            chr,
            pos,
            var_id,
            ref,
            alt,
            lrt_chisq,
            lrt_df,
            p_lrt,
            beta
        )
        writeLines(lineout, out_con)
    }

    pgenlibr::ClosePgen(pgen)
    close(out_con)
    close(pb)

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
    touch ${prefix}.gwas.tsv.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        r-base: \$(Rscript -e "cat(strsplit(as.character(R.version[\\"version.string\\"]), \\" \\")[[1]][3])")
        pgenlibr: \$(Rscript -e "cat(as.character(utils::packageVersion(\\"pgenlibr\\")))")
    END_VERSIONS
    """
}
