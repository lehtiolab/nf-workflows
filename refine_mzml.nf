/*
==============================
MZML REFINER PIPELINE
==============================
For when you have discovered you have systematic errors (i.e. global m/z shifts) in your
spectra.

@Authors
Jorrit Boekel @glormph
*/


params.isobaric = false
params.activation = 'hcd'
params.outdir = 'results'

if (params.isobaric) {
  mods = file([tmt10plex: "data/tmtmods.txt", tmt6plex: "data/tmtmods.txt"][params.isobaric])
} else {
  mods = file("data/labelfreemods.txt")
}
tdb = file(params.tdb)
plextype = params.isobaric ? params.isobaric.replaceFirst(/[0-9]+plex/, "") : 'false'
msgfprotocol = [tmt:4, itraq:2, false:0][plextype]
instrument = params.instrument ? params.instrument : false
msgfinstrument = [velos:1, qe:3, false:0][instrument]


/* input is mzmldef file, tsv:
mzML\tfn_id\n
*/

Channel
  .from(file("${params.mzmldef}").readLines())
  .map { it -> it.tokenize('\t') }
  .map { it -> [file(it[0]), file(it[0]).baseName.replaceFirst(/.*\/(\S+)\.mzML/, "\$1"), it[1]] } // file, samplename, fn_dbid
  .set { mzml_msgf }


process makeDecoyReverseDB {
  container 'biopython/biopython'

  input:
  file(tdb)

  output:
  file('tddb.fasta') into concatdb

  """
  #!/usr/bin/env python3
  from Bio import SeqIO
  with open('$tdb') as fp, open('tddb.fasta', 'w') as wfp:
    for target in SeqIO.parse(fp, 'fasta'):
      SeqIO.write(target, wfp, 'fasta')
      decoy = target[::-1] 
      decoy.description = decoy.description.replace('ENS', 'decoy_ENS')
      decoy.id = 'decoy_{}'.format(decoy.id)
      SeqIO.write(decoy, wfp, 'fasta')
  """
}


process msgfPlus {
  container 'quay.io/biocontainers/msgf_plus:2017.07.21--py27_0'

  input:
  set file(x), val(sample), val(dbid) from mzml_msgf
  file(db) from concatdb
  file mods

  output:
  set file(x), val(sample), file("search.mzid"), val(dbid) into mzml_mzid
  
  """
  msgf_plus -Xmx16g -d $db -s $x -o search.mzid -thread 12 -mod $mods -tda 0 -t 10.0ppm -ti -1,2 -m 0 -inst ${msgfinstrument} -e 1 -protocol ${msgfprotocol} -ntt 2 -minLength 7 -maxLength 50 -minCharge 2 -maxCharge 6 -n 1 -addFeatures 1
  rm ${db.baseName.replaceFirst(/\.fasta/, "")}.c*
  """
}

process mzRefine {
  container 'quay.io/biocontainers/proteowizard:3_0_9992--h2d50403_2'

  publishDir "${params.outdir}", mode: 'copy', overwrite: true

  input:
  set file(mzml), val(sample), file("${sample}.mzid"), val(dbid) from mzml_mzid

  output:
  file("${dbid}___${sample}.refined.mzML")

  """
  msconvert $mzml --outfile ${dbid}___${sample}.refined.mzML --filter "mzRefiner ${sample}.mzid thresholdValue=-1e-10 thresholdStep=10 maxSteps=2 thresholdScore=SpecEValue"
  """
}
