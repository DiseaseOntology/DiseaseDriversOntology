# config
MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all
.DELETE_ON_ERROR:
.SUFFIXES:
.SECONDARY:
.NOTPARALLEL:

DD = src/ontology/disdriv
EDIT = src/ontology/disdriv-edit.owl
OBO = http://purl.obolibrary.org/obo/

# Set the software versions to use
ROBOT_VRS = 1.9.5
FASTOBO_VRS = 0.4.6

# ***NEVER run make commands in parallel (do NOT use the -j flag)***

# to make a release, use `make release`
# to run QC tests on disdriv-edit.owl, use `make test`

# Release process:
# 1. Build product(s)
# 2. Validate syntax of OBO-format products with fastobo-validator
# 3. Verify logical structure of products with SPARQL queries
# 4. Generate post-build reports (counts, etc.)

.PHONY: release all
release: test products verify publish post
	@echo "Release complete!"

all: release

.PHONY: FORCE
FORCE:


##########################################
## SETUP
##########################################

.PHONY: clean
clean:
	rm -rf build

build build/update build/reports build/reports/temp build/translations:
	mkdir -p $@

# ----------------------------------------
# ROBOT
# ----------------------------------------

# ROBOT is automatically updated
ROBOT := java -jar build/robot.jar

.PHONY: check_robot
check_robot:
	@if [[ -f build/robot.jar ]]; then \
		VRS=$$($(ROBOT) --version) ; \
		if [[ "$$VRS" != *"$(ROBOT_VRS)"* ]]; then \
			printf "\e[1;37mUpdating\e[0m from $$VRS to $(ROBOT_VRS)...\n" ; \
			rm -rf build/robot.jar && $(MAKE) build/robot.jar ; \
		fi ; \
	else \
		echo "Downloading ROBOT version $(ROBOT_VRS)..." ; \
		$(MAKE) build/robot.jar ; \
	fi

# run `make refresh_robot` if ROBOT is not working correctly
.PHONY: refresh_robot
refresh_robot:
	rm -rf build/robot.jar && $(MAKE) build/robot.jar

build/robot.jar: | build
	@curl -L -o $@ https://github.com/ontodev/robot/releases/download/v$(ROBOT_VRS)/robot.jar

# ----------------------------------------
# FASTOBO
# ----------------------------------------

# fastobo is used to validate OBO structure
FASTOBO := build/fastobo-validator

.PHONY: check_fastobo
check_fastobo:
	@if [[ -f $(FASTOBO) ]]; then \
		VRS=$$($(FASTOBO) --version) ; \
		if [[ "$$VRS" != *"$(FASTOBO_VRS)"* ]]; then \
			printf "\e[1;37mUpdating\e[0m from $$VRS to $(FASTOBO_VRS)...\n" ; \
			rm -rf build/fastobo-validator && $(MAKE) $(FASTOBO) ; \
		fi ; \
	else \
		printf "\e[1;37mDownloading\e[0m fastobo-validator version $(FASTOBO_VRS)...\n" ; \
		$(MAKE) $(FASTOBO) ; \
	fi

$(FASTOBO): | build
	@if [[ $$(uname -m) == 'x86_64' ]]; then \
		curl -Lk -o build/fastobo-validator.zip https://github.com/fastobo/fastobo-validator/releases/download/v$(FASTOBO_VRS)/fastobo-validator_null_x86_64-apple-darwin.zip ; \
		cd build && unzip -DD fastobo-validator.zip fastobo-validator && rm fastobo-validator.zip ; \
	else \
		if [[ $$(command -v cargo) != *"cargo" ]]; then \
			printf "\e[1;33mWARNING:\e[0m fastobo-validator must be built from source on ARM64 machines\n" ; \
			printf " --> Install the Rust programming language, then repeat desired make command\n" ; \
			printf "\e[1;33mSKIPPING\e[0m fastobo-validator install\n\n" ; \
		else \
			echo "fastobo-validator must be built from source on ARM64 machines, one moment..." ; \
			cargo install --quiet --root $(dir $@) \
				--git "https://github.com/fastobo/fastobo-validator/" \
				--tag "v$(FASTOBO_VRS)" fastobo-validator && \
			mv build/bin/fastobo-validator $@ && rm -d build/bin ; \
		fi ; \
	fi

# ----------------------------------------
# FILE UTILITIES
# ----------------------------------------

# cleans csv files from a directory, optionally matching pattern(s)
#  --> to prevent existing file inclusion in concat_csv
# args = input-directory, pattern(s)-to-match-files (should end with .csv)
define clean_existing_csv
	@PATTERN=($(2)) ; \
	if [ "$$PATTERN" ]; then \
		TMP_FILES=$$(find $(1) -name "$(firstword $(2))" $(patsubst %,-o -name "%",$(wordlist 2,$(words $(2)),$(2)))) ; \
	else \
		TMP_FILES=$$(find $(1) -name "*.csv") ; \
	fi ; \
	if [ "$$TMP_FILES" ]; then \
		rm -f $$TMP_FILES ; \
	fi
endef

# concatenate multiple CSV files into one
# args = file category ('TEST' to error, if output), output-file, input-directory, pattern(s)-to-match-files (should end with .csv)
define concat_csv
	@PATTERN=($(4)) ; \
	if [ "$$PATTERN" ]; then \
		TMP_FILES=$$(find $(3) -name "$(firstword $(4))" $(patsubst %,-o -name "%",$(wordlist 2,$(words $(4)),$(4)))) ; \
	else \
		TMP_FILES=$$(find $(3) -name "*.csv") ; \
	fi ; \
	if [ "$$TMP_FILES" ]; then \
		awk 'BEGIN { OFS = FS = "," } ; { \
			if (FNR == 1) { \
				gsub(/^.*\/|\.csv/, "", FILENAME) ; \
				if (NR != 1) { print "" } ; \
				print "$(1): " FILENAME ; print $$0 \
			} \
			else { print $$0 } \
		}' $$TMP_FILES > $(2) \
        && rm -f $$TMP_FILES ; \
		if [ "$(1)" = "TEST" ] ; then \
			exit 1 ; \
		fi ; \
	elif [ "$(1)" = "TEST" ]; then \
		echo "" > $(2) ; \
	fi
endef


##########################################
## CI TESTS & DIFF
##########################################

.PHONY: ci_test test report reason verify-edit quarterly_test

# Continuous Integration (CI) testing
test: reason report verify-edit
	@echo ""

# Report for general issues on disdriv-edit
report: build/reports/report-obo.tsv

.PRECIOUS: build/reports/report-obo.tsv

build/reports/report-obo.tsv: $(EDIT) | check_robot build/reports
	@echo -e "\n## OBO dashboard QC report\nFull report at $@"
	@$(ROBOT) report \
	 --input $< \
	 --labels true \
	 --output $@

# Simple reasoning test
reason: build/disdriv-edit-reasoned.owl

build/disdriv-edit-reasoned.owl: $(EDIT) | check_robot build
	@$(ROBOT) reason \
	 --input $< \
	 --create-new-ontology false \
	 --annotate-inferred-axioms false \
	 --exclude-duplicate-axioms true \
	 --equivalent-classes-allowed "asserted-only" \
	 --output $@
	@echo -e "\n## Reasoning completed successfully!"

# Verify disdriv-edit.owl
EDIT_V_QUERIES := $(wildcard src/sparql/verify/edit-verify-*.rq src/sparql/verify/verify-*.rq)

.PRECIOUS: build/reports/edit-verify.csv
verify-edit: build/reports/edit-verify.csv
build/reports/edit-verify.csv: $(EDIT) | check_robot build/reports/temp
	$(call clean_existing_csv,$(word 2,$|),edit-verify-*.csv verify-*.csv)
	@$(ROBOT) verify \
	 --input $< \
	 --queries $(EDIT_V_QUERIES) \
	 --fail-on-violation false \
	 --output-dir $(word 2,$|)
	$(call concat_csv,TEST,$@,$(word 2,$|),edit-verify-*.csv verify-*.csv)


##########################################
## RELEASE PRODUCTS
##########################################

.PHONY: products
products: primary human merged base subsets release_reports src/facets.tsv.gz

# release vars
TS = $(shell date +'%d:%m:%Y %H:%M')
DATE := $(shell date +'%Y-%m-%d')
RELEASE_PREFIX := "$(OBO)disdriv/releases/$(DATE)/"

# ----------------------------------------
# DISDRIV
# ----------------------------------------

.PHONY: primary
primary: $(DD).owl $(DD).obo $(DD).json

$(DD).owl: $(EDIT) src/sparql/build/add_en_tag.ru | \
 check_robot rel_test
	@$(ROBOT) reason \
	 --input $< \
	 --create-new-ontology false \
	 --annotate-inferred-axioms false \
	 --exclude-duplicate-axioms true \
	query \
	 --input $< \
	 --update $(word 2,$^) \
	annotate \
	 --version-iri "$(RELEASE_PREFIX)$(notdir $@)" \
	 --annotation oboInOwl:date "$(TS)" \
	 --annotation owl:versionInfo "$(DATE)" \
	 --output $@
	@echo "Created $@"


##########################################
## VERIFY build products
##########################################

.PHONY: verify

verify:
	@$(ROBOT) reason -i $(DD).owl
	@echo -e "\n## disdriv.owl verified successfully!"


##########################################
## POST-BUILD REPORT
##########################################

# Count classes, imports, and logical defs from old and new
post: build/reports/branch-count.tsv

# all report queries
QUERIES := $(wildcard src/sparql/build/*-report.rq)

# target names for previous release reports
LAST_REPORTS := $(foreach Q,$(QUERIES), build/reports/$(basename $(notdir $(Q)))-last.tsv)
last-reports: $(LAST_REPORTS)
build/reports/%-last.tsv: src/sparql/build/%.rq build/disdriv-merged-last.owl | check_robot build/reports
	@echo "Counting: $(notdir $(basename $@))"
	@$(ROBOT) query \
	 --input $(word 2,$^) \
	 --query $< $@

# target names for current release reports
NEW_REPORTS := $(foreach Q,$(QUERIES), build/reports/$(basename $(notdir $(Q)))-new.tsv)
new-reports: $(NEW_REPORTS)
build/reports/%-new.tsv: src/sparql/build/%.rq $(DM).owl | check_robot build/reports
	@echo "Counting: $(notdir $(basename $@))"
	@$(ROBOT) query \
	 --input $(word 2,$^) \
	 --query $< $@

# create a count of asserted and total (asserted + inferred) classes in each branch
#	disdriv-edit.owl could be used in place of disdriv-non-classified (pre-reasoned = same results)
branch_reports = $(foreach O, disdriv-non-classified disdriv, build/reports/temp/branch-count-$(O).tsv)

.INTERMEDIATE: $(branch_reports)
$(branch_reports): build/reports/temp/branch-count-%.tsv: src/ontology/%.owl \
 src/sparql/build/branch-count.rq | check_robot build/reports/temp
	@echo "Counting all branches in $<..."
	@$(ROBOT) query \
	 --input $< \
	 --query $(word 2,$^) $@

build/reports/branch-count.tsv: $(branch_reports)
	@join -t $$'\t' -o $$'\t' <(sed '/^?/d' $< | sort -k1) <(sed '/^?/d' $(word 2,$^) | sort -k1) > $@
	@awk 'BEGIN{ FS=OFS="\t" ; print "branch\tasserted\tinferred\ttotal" } \
	 {print $$1, $$2, $$3-$$2, $$3}' $@ > $@.tmp && mv $@.tmp $@
	@echo "Branch counts available at $@"