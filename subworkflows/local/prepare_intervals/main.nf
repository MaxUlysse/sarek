//
// PREPARE INTERVALS
//

// Initialize channels based on params or indices that were just built
// For all modules here:
// A when clause condition is defined in the conf/modules.config to determine if the module should be run

include { BUILD_INTERVALS                                     } from '../../../modules/local/build_intervals/main'
include { CREATE_INTERVALS_BED                                } from '../../../modules/local/create_intervals_bed/main'
include { GATK4_INTERVALLISTTOBED as INTERVALLISTTOBED_BAIT   } from '../../../modules/nf-core/gatk4/intervallisttobed/main'
include { GATK4_INTERVALLISTTOBED as INTERVALLISTTOBED_TARGET } from '../../../modules/nf-core/gatk4/intervallisttobed/main'
include { TABIX_BGZIPTABIX as TABIX_BGZIPTABIX_INTERVAL_SPLIT } from '../../../modules/nf-core/tabix/bgziptabix/main'

workflow PREPARE_INTERVALS {
    take:
    fasta_fai    // mandatory [ fasta_fai ]
    intervals    // [ params.intervals ]
    bait         // [ params.bait ]
    no_intervals // [ params.no_intervals ]

    main:
    versions = Channel.empty()

    intervals_bed        = Channel.empty() // List of [ bed, num_intervals ], one for each region
    intervals_bed_gz_tbi = Channel.empty() // List of [ bed.gz, bed,gz.tbi, num_intervals ], one for each region
    intervals_combined   = Channel.empty() // Single bed file containing all intervals

    if (no_intervals) {
        file("${params.outdir}/no_intervals.bed").text        = "no_intervals\n"
        file("${params.outdir}/no_intervals.bed.gz").text     = "no_intervals\n"
        file("${params.outdir}/no_intervals.bed.gz.tbi").text = "no_intervals\n"

        bait_bed             = Channel.value([])
        intervals_bed        = Channel.fromPath(file("${params.outdir}/no_intervals.bed")).map{ it -> [ it, 0 ] }
        intervals_bed_gz_tbi = Channel.fromPath(file("${params.outdir}/no_intervals.bed.{gz,gz.tbi}")).collect().map{ it -> [ it, 0 ] }
        intervals_combined   = Channel.fromPath(file("${params.outdir}/no_intervals.bed")).map{ it -> [ [ id:it.simpleName ], it ] }
    } else if (params.step != 'annotate' && params.step != 'controlfreec') {
        // If no interval/target file is provided, then generated intervals from FASTA file
        if (!intervals) {
            bait_bed = Channel.value([])

            BUILD_INTERVALS(fasta_fai.map{it -> [ [ id:it.baseName ], it ] })

            intervals_combined = BUILD_INTERVALS.out.bed

            CREATE_INTERVALS_BED(intervals_combined.map{ meta, path -> path }).bed

            intervals_bed = CREATE_INTERVALS_BED.out.bed

            versions = versions.mix(BUILD_INTERVALS.out.versions)
            versions = versions.mix(CREATE_INTERVALS_BED.out.versions)
        } else {
            if (bait) {
                INTERVALLISTTOBED_BAIT(bait)
                bait_bed = INTERVALLISTTOBED_BAIT.out.bed
                versions = versions.mix(INTERVALLISTTOBED_BAIT.out.versions)
            }

            INTERVALLISTTOBED_TARGET(intervals_combined)
            intervals_combined = INTERVALLISTTOBED_TARGET.out.bed

            intervals_bed = CREATE_INTERVALS_BED(file(intervals)).out.bed

            versions = versions.mix(CREATE_INTERVALS_BED.out.versions)
            versions = versions.mix(INTERVALLISTTOBED_TARGET.out.versions)
        }

        // Now for the intervals.bed the following operations are done:
        // 1. Intervals file is split up into multiple bed files for scatter/gather
        // 2. Each bed file is indexed

        // 1. Intervals file is split up into multiple bed files for scatter/gather & grouping together small intervals
        intervals_bed = intervals_bed.flatten()
            .map{ intervalFile ->
                def duration = 0.0
                for (line in intervalFile.readLines()) {
                    final fields = line.split('\t')
                    if (fields.size() >= 5) duration += fields[4].toFloat()
                    else {
                        start = fields[1].toInteger()
                        end = fields[2].toInteger()
                        duration += (end - start) / params.nucleotides_per_second
                    }
                }
                [ duration, intervalFile ]
            }.toSortedList({ a, b -> b[0] <=> a[0] })
            .flatten().collate(2).map{ duration, intervalFile -> intervalFile }.collect()
            // Adding number of intervals as elements
            .map{ it -> [ it, it.size() ] }
            .transpose()

        // 2. Create bed.gz and bed.gz.tbi for each interval file. They are split by region (see above)
        TABIX_BGZIPTABIX_INTERVAL_SPLIT(intervals_bed.map{ file, num_intervals -> [ [ id:file.baseName], file ] })

        intervals_bed_gz_tbi = TABIX_BGZIPTABIX_INTERVAL_SPLIT.out.gz_tbi.map{ meta, bed, tbi -> [ bed, tbi ] }.toList()
            // Adding number of intervals as elements
            .map{ it -> [ it, it.size() ] }
            .transpose()

        versions = versions.mix(TABIX_BGZIPTABIX_INTERVAL_SPLIT.out.versions)
    }

    intervals_bed_combined = intervals_combined.map{meta, bed -> bed }.collect()

    emit:
    // Intervals split for parallel execution
    intervals_bed          // [ intervals.bed, num_intervals ]
    intervals_bed_gz_tbi   // [ target.bed.gz, target.bed.gz.tbi, num_intervals ]
    // All intervals in one file
    intervals_bed_combined // [ intervals.bed ]
    bait_bed               // [ bait.bed ]

    versions               // [ versions.yml ]
}
