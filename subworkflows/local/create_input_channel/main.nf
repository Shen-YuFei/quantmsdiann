//
// Create channel for input file (DIA-NN only pipeline)
//
include { SDRF_PARSING } from '../../../modules/local/sdrf_parsing/main'



workflow CREATE_INPUT_CHANNEL {
    take:
    ch_sdrf
    ch_downloaded_files  // collected list of [name, path] pairs from PRIDEPY_DOWNLOAD, or empty list

    main:
    ch_versions = channel.empty()

    // Validate --local_input_type against supported local file formats when using --root_folder.
    // Redundant with the schema enum, but still catches the case where schema validation is disabled.
    def allowedLocalInputTypes = ['mzML', 'raw', 'd', 'dia', 'd.tar', 'd.tar.gz', 'd.zip', 'wiff']
    if (params.root_folder && params.local_input_type && !allowedLocalInputTypes.contains(params.local_input_type)) {
        exit(1, "ERROR: Unsupported --local_input_type '${params.local_input_type}'. Supported values: ${allowedLocalInputTypes.join(', ')}")
    }

    // Known raw-data extensions; order matters, so strip longest/compound ones first
    // so 'sample.d.zip' -> 'sample', not 'sample.d'.
    def knownRawExts = ['.d.tar.gz', '.d.tar', '.d.zip', '.mzML.gz', '.raw.gz',
                        '.mzML', '.raw', '.dia', '.d', '.wiff']

    // Always parse as SDRF using DIA-NN converter
    SDRF_PARSING(ch_sdrf)
    ch_versions = ch_versions.mix(SDRF_PARSING.out.versions)
    ch_expdesign = SDRF_PARSING.out.ch_expdesign
    ch_diann_cfg = SDRF_PARSING.out.ch_diann_cfg


    // Extract experiment_id from the SDRF filename
    ch_experiment_id = ch_sdrf.map { sdrf_file -> file(sdrf_file).baseName }

    ch_experiment_id
        .combine(ch_expdesign)
        .splitCsv(header: true, sep: '\t')
        .map { experiment_id, row ->
            def filestr
            def is_wiff = (row.IsWiff?.toString()?.toLowerCase() == 'true')

            if (!params.root_folder) {
                filestr = row.URI?.toString()?.trim() ? row.URI.toString() : row.Filename.toString()

                if (is_wiff) {
                    def scan_filestr = row.Associated_URI?.toString()?.trim() ? row.Associated_URI.toString() : filestr + ".scan"
                    filestr = [filestr, scan_filestr]
                }
            } else {
                filestr = row.Filename.toString()
                filestr = params.root_folder + File.separator + filestr
                if (params.local_input_type) {
                    // Strip the longest matching known raw-data extension (covers
                    // compound suffixes like .d.zip / .d.tar.gz from the SDRF),
                    // then append the target extension.
                    def stem = filestr
                    def stemLower = stem.toLowerCase()

                    def matched = knownRawExts.find { ext ->
                        stemLower.endsWith(ext.toLowerCase())
                    }

                    if (matched) {
                        stem = stem.substring(0, stem.length() - matched.length())
                    } else if (stem.lastIndexOf('.') > 0) {
                        stem = stem.take(stem.lastIndexOf('.'))
                    }
                    filestr = stem + '.' + params.local_input_type
                }

                if (is_wiff) {
                    filestr = [filestr, filestr + ".scan"]
                }
            }
            return [filestr, experiment_id, row]
        }
        .groupTuple(by: 0)
        .combine(ch_downloaded_files)
        .map { filestr, experiment_ids, rows, downloaded_files ->
            def experiment_id = experiment_ids[0]
            def is_wiff = (rows[0].IsWiff?.toString()?.toLowerCase() == 'true')
            def wrapper = [acquisition_method: "", experiment_id: experiment_id]
            return create_meta_channel_grouped(filestr, rows, wrapper, downloaded_files)
        }
        .set { ch_meta_config_dia }

    emit:
    ch_meta_config_dia // [meta, spectra_file]
    ch_expdesign
    ch_diann_cfg
    versions = ch_versions
}

// Function to get list of [meta, [ spectra_files ]]
def create_meta_channel_grouped(def filestr, List rows, Map wrapper, List downloaded_files) {
    def meta = [:]

    def base_row = rows[0]

    def main_file_str = filestr instanceof List ? filestr[0] : filestr
    def fileName = file(main_file_str).name
    def dotIndex = fileName.lastIndexOf('.')
    meta.id = dotIndex > 0 ? fileName.take(dotIndex) : fileName
    meta.experiment_id = wrapper.experiment_id

    meta.is_wiff = (base_row.IsWiff?.toString()?.toLowerCase() == 'true')

    // Substitute SDRF URIs with pre-downloaded local files (by filename) when available
    if (downloaded_files) {
        if (filestr instanceof List) {
            filestr = filestr.collect { f ->
                def match = downloaded_files.find { it[0] == file(f).name }
                match ? match[1].toString() : f
            }
        } else {
            def match = downloaded_files.find { it[0] == file(filestr).name }
            if (match) {
                filestr = match[1].toString()
            }
        }
    }

    // existence check
    def files_to_check = filestr instanceof List ? filestr : [filestr]
    files_to_check.each { f ->
        if (!file(f).exists()) {
            exit(1, "ERROR: Please check input file -> File Uri does not exist!\n${f}")
        }
    }

    // Detect acquisition method from SDRF or fallback to --dda param
    def acqMethod = base_row.AcquisitionMethod?.toString()?.trim() ?: ""
    if (acqMethod.toLowerCase().contains("data-independent acquisition") || acqMethod.toLowerCase().contains("dia")) {
        meta.acquisition_method = "dia"
    } else if (acqMethod.toLowerCase().contains("data-dependent acquisition") || acqMethod.toLowerCase().contains("dda")) {
        meta.acquisition_method = "dda"
    } else if (acqMethod.isEmpty()) {
        meta.acquisition_method = params.dda ? "dda" : "dia"
    } else {
        log.error("Unsupported acquisition method: '${acqMethod}'. This pipeline supports DIA and DDA. Found in file: ${filestr}")
        exit(1)
    }

    meta.dissociationmethod = base_row.DissociationMethod?.toString()?.trim() ?: ""
    wrapper.acquisition_method = meta.acquisition_method

    def labels = rows.collect { it.Label?.toString()?.trim() }.findAll { it }.unique()
    meta.labelling_type = labels.join(';')

    def is_plexdia = labels.size() > 1 || (labels.size() == 1 && !labels[0].toLowerCase().contains("label free"))
    meta.plexdia = is_plexdia

    def enzymes = rows.collect { it.Enzyme?.toString()?.trim() }.findAll { it }.unique()
    if (enzymes.size() > 1) {
        log.error("Currently only one enzyme is supported per file. Found conflicting enzymes for ${filestr}: '${enzymes}'.")
        exit(1)
    }
    meta.enzyme = enzymes ? enzymes[0] : null

    def fixedMods = rows.collect { it.FixedModifications?.toString()?.trim() }.findAll { it }.unique()
    if (fixedMods.size() > 1) {
        log.error("SDRF conflict: Multiple FixedModifications (${fixedMods.join(',')}) found for file ${meta.id}. Please fix the SDRF.")
    }
    // Empty string (not null) when no fixed mod is declared: null would be
    // interpolated as the literal "null" into the downstream --fix_mod flag.
    // No fixed modification is valid (e.g. low-input DVP / single-cell prep
    // without reduction+alkylation, so no Carbamidomethyl); DIA-NN and
    // quantms-utils dianncfg both run fine with an empty fixed-mod set.
    meta.fixedmodifications = fixedMods ? fixedMods[0] : ''

    // Validate required SDRF columns. FixedModifications is intentionally NOT
    // required: many label-free / low-input experiments declare no fixed mod.
    def requiredColumns = [
        'Label': meta.labelling_type,
        'Enzyme': meta.enzyme
    ]

    def missingColumns = []
    requiredColumns.each { colName, colValue ->
        if (colValue == null || colValue.toString().isEmpty()) {
            missingColumns.add(colName)
        }
    }

    if (missingColumns.size() > 0) {
        log.error("ERROR: Missing or empty required SDRF columns for file '${filestr}': ${missingColumns.join(', ')}")
        log.error("These parameters must be specified in the SDRF file. Please check your SDRF annotation.")
        exit(1)
    }

    def autoCalibrating = params.mass_acc_automatic && !params.skip_preliminary_analysis
    def precursorTolerance = resolve_mass_tolerance(
        base_row.PrecursorMassTolerance, base_row.PrecursorMassToleranceUnit,
        'precursor', filestr, autoCalibrating,
        params.precursor_mass_tolerance, params.precursor_mass_tolerance_unit
    )
    meta.precursormasstolerance = precursorTolerance[0]
    meta.precursormasstoleranceunit = precursorTolerance[1]

    def fragmentTolerance = resolve_mass_tolerance(
        base_row.FragmentMassTolerance, base_row.FragmentMassToleranceUnit,
        'fragment', filestr, autoCalibrating,
        params.fragment_mass_tolerance, params.fragment_mass_tolerance_unit
    )
    meta.fragmentmasstolerance = fragmentTolerance[0]
    meta.fragmentmasstoleranceunit = fragmentTolerance[1]

    if (base_row.VariableModifications != null && !base_row.VariableModifications.toString().trim().isEmpty()) {
        meta.variablemodifications = base_row.VariableModifications
    } else {
        meta.variablemodifications = params.variable_mods
    }

    meta.ms1minmz = base_row.MS1MinMz?.toString()?.trim() ?: ""
    meta.ms1maxmz = base_row.MS1MaxMz?.toString()?.trim() ?: ""
    meta.ms2minmz = base_row.MS2MinMz?.toString()?.trim() ?: ""
    meta.ms2maxmz = base_row.MS2MaxMz?.toString()?.trim() ?: ""

    def resolved_files = filestr instanceof List ? filestr.collect { file(it) } : file(filestr)
    return [meta, resolved_files]
}

def resolve_mass_tolerance(value, unit, level, filestr, automatic, fallbackValue, fallbackUnit) {
    def valueText = value?.toString()?.trim()
    def unitText = unit?.toString()?.trim()
    if (!valueText && !unitText) {
        if (automatic) {
            log.info("Automatic DIA-NN mass accuracy calibration enabled for '${filestr}'; ${level} tolerance is not specified in SDRF.")
            // Do not present configured fallback values as SDRF annotations.
            // Downstream calibration failures retain their existing warning and fallback path.
            return [null, null]
        }
        log.warn("No ${level} mass tolerance in SDRF for '${filestr}'. Using default: ${fallbackValue} ${fallbackUnit}")
        return [fallbackValue, fallbackUnit]
    }
    if (!valueText || !unitText) {
        error("Incomplete ${level} mass tolerance for '${filestr}': specify both value and unit in SDRF.")
    }
    if (!['ppm', 'da'].contains(unitText.toLowerCase())) {
        error("Invalid ${level} mass tolerance unit '${unitText}' for '${filestr}': expected ppm or Da.")
    }
    double parsedValue
    try {
        parsedValue = Double.parseDouble(valueText)
    } catch (NumberFormatException e) {
        error("Invalid ${level} mass tolerance '${valueText}' for '${filestr}': expected a finite, non-negative number.")
    }
    if (!Double.isFinite(parsedValue) || parsedValue < 0) {
        error("Invalid ${level} mass tolerance '${valueText}' for '${filestr}': expected a finite, non-negative number.")
    }
    return [parsedValue, unitText]
}
