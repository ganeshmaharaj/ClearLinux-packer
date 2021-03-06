.DEFAULT_GOAL := help

BOX_NAME := ClearLinux
OWNER ?= AntonioMeireles
REPOSITORY := $(OWNER)/$(BOX_NAME)

VERSION ?= $(shell curl -Ls $(CLR_BASE_URL)/latest)
CLR_BASE_URL := https://download.clearlinux.org
CLR_RELEASE_URL := $(CLR_BASE_URL)/releases/$(VERSION)/clear
BUILD_ID ?= $(shell date -u '+%Y-%m-%d-%H%M')
NV := $(BOX_NAME)-$(VERSION)

SEED_PREFIX = clear-$(VERSION)
VMDK := $(SEED_PREFIX)-vmware.vmdk
LIBVIRT := $(SEED_PREFIX)-kvm.img

VMDK_SEED_URL := $(CLR_RELEASE_URL)/$(VMDK).xz
LIBVIRT_SEED_URL := $(CLR_RELEASE_URL)/$(LIBVIRT).xz
MEDIADIR := media
BOXDIR := boxes
PWD := `pwd`

VAGRANT_REPO = https://app.vagrantup.com/api/v1/box/$(REPOSITORY)

.PHONY: help
help:
	@echo "available 'make' targets:"
	@echo
	@grep -E "^.*:.*?## .*$$" $(MAKEFILE_LIST) | grep -vE "(grep|BEGIN)" | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\t\033[36m%-30s\033[0m %s\n", $$1, $$2}' | \
		VERSION=$(VERSION) envsubst
	@echo
	@echo "By default the target VERSION is the 'latest' one, currently $(VERSION)"
	@echo "To target a specific one add 'VERSION=...' to your make invocation"
	@echo
$(MEDIADIR)/OVMF.fd:
	@mkdir -p $(MEDIADIR)
	@curl -sSL $(CLR_BASE_URL)/image/OVMF.fd -o $(MEDIADIR)/OVMF.fd

$(MEDIADIR)/$(VMDK):
	@mkdir -p $(MEDIADIR)
	@echo "downloading v$(VERSION) base image [VMDK]..."
	@curl -sSL $(VMDK_SEED_URL) -o $(MEDIADIR)/$(VMDK).xz
	@cd $(MEDIADIR) && unxz $(VMDK).xz && vmware-vdiskmanager -x 40Gb $(VMDK) && cd -
	@echo "v$(VERSION) base image unpacked..."

$(MEDIADIR)/$(LIBVIRT):
	@mkdir -p $(MEDIADIR)
	@echo "downloading v$(VERSION) base image [KVM/libvirt]..."
	@curl -sSL $(LIBVIRT_SEED_URL) -o /tmp/$(LIBVIRT).xz
	@unxz -f /tmp/$(LIBVIRT).xz && mv /tmp/$(LIBVIRT) $(MEDIADIR)/
	@echo "v$(VERSION) base image unpacked..."

.PHONY: seed
seed: $(MEDIADIR)/seed-$(VERSION)

$(MEDIADIR)/$(NV).ova: $(MEDIADIR)/$(VMDK)
	@mkdir -p $(MEDIADIR)/seed-$(VERSION)
	@for f in pv.vmx vmx vmxf vmsd plist; do                                           \
		cp template/$(BOX_NAME).$$f.tmpl $(MEDIADIR)/seed-$(VERSION)/$(NV).$$f; done
	@(cd $(MEDIADIR)/seed-$(VERSION); gsed -i "s,VERSION,$(VERSION)," $(BOX_NAME)-*)
	@ln -sf ../$(VMDK) $(MEDIADIR)/seed-$(VERSION)/
	@(cd $(MEDIADIR)/seed-$(VERSION);                                      \
		gsed -i "s,VMDK_SIZE,$$(/usr/bin/stat -f"%z" ../$(VMDK))," $(BOX_NAME)-* )
	@echo "vmware fusion VM (v$(VERSION)) syntetised from vmdk"
	@ovftool $(MEDIADIR)/seed-$(VERSION)/$(NV).vmx $(MEDIADIR)/$(NV).ova
	@cp $(MEDIADIR)/seed-$(VERSION)/$(NV).pv.vmx $(MEDIADIR)/seed-$(VERSION)/$(NV).vmx

.PHONY: all virtualbox vmware libvirt
all: virtualbox vmware libvirt ## Packer Build   All box flavors

virtualbox: $(BOXDIR)/virtualbox/$(NV).virtualbox.box ## Packer Build   VirtualBox

vmware: $(BOXDIR)/vmware/$(NV).vmware.box ## Packer Build   VMware

libvirt: $(BOXDIR)/libvirt/$(NV).libvirt.box ## Packer Build   LibVirt

$(BOXDIR)/libvirt/$(NV).libvirt.box:  $(MEDIADIR)/$(LIBVIRT) $(MEDIADIR)/OVMF.fd
	packer build -force -var "name=$(BOX_NAME)" -var "version=$(VERSION)" -var "box_tag=$(REPOSITORY)" packer.conf.libvirt.json

$(BOXDIR)/virtualbox/$(NV).virtualbox.box: $(MEDIADIR)/$(NV).ova
	packer build -force -var "name=$(BOX_NAME)" -var "version=$(VERSION)" -var "box_tag=$(REPOSITORY)" packer.conf.virtualbox.json

$(BOXDIR)/vmware/$(NV).vmware.box: $(MEDIADIR)/$(NV).ova
	packer build -force -var "name=$(BOX_NAME)" -var "version=$(VERSION)" -var "box_tag=$(REPOSITORY)" packer.conf.vmware.json

.PHONY: release
release: ## Vagrant Cloud  create a new release
	( cat new.tmpl.json | envsubst | curl --silent --header "Content-Type: application/json" \
		--header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" $(VAGRANT_REPO)/versions      \
		--data-binary @- ) && echo "created release $(VERSION) on Vagrant Cloud"
	curl --header "Content-Type: application/json" \
		--header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/${VERSION}/providers \
		--data '{"provider": {"name": "virtualbox"}}'
	curl --header "Content-Type: application/json" \
		--header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/${VERSION}/providers \
		--data '{"provider": {"name": "vmware_desktop"}}'
	curl --header "Content-Type: application/json" \
		--header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/${VERSION}/providers \
		--data '{"provider": {"name": "libvirt"}}'

.PHONY: upload-libvirt-box
upload-libvirt-box: $(BOXDIR)/libvirt/$(NV).libvirt.box ## Vagrant Cloud  LibVirt upload
	@curl $$(curl -s --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/${VERSION}/provider/libvirt/upload | jq .upload_path | tr -d \") \
		--upload-file $(BOXDIR)/libvirt/$(NV).libvirt.box && echo "LibVirt box (v$(VERSION)) uploaded"

.PHONY: upload-virtualbox-box
upload-virtualbox-box: $(BOXDIR)/virtualbox/$(NV).virtualbox.box ## Vagrant Cloud  VirtualBox upload
	@curl $$(curl -s --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/${VERSION}/provider/virtualbox/upload | jq .upload_path | tr -d \") \
		--upload-file $(BOXDIR)/virtualbox/$(NV).virtualbox.box && echo "VirtualBox box (v$(VERSION)) uploaded"

.PHONY: upload-vmware-box
upload-vmware-box: $(BOXDIR)/vmware/$(NV).vmware.box ## Vagrant Cloud  VMware upload
	@curl $$(curl -s --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/${VERSION}/provider/vmware_desktop/upload | jq .upload_path | tr -d \") \
		--upload-file $(BOXDIR)/vmware/$(NV).vmware.box && echo "VMware box (v$(VERSION)) uploaded"

.PHONY: upload-all publish
upload-all: upload-virtualbox-box upload-libvirt-box upload-vmware-box ## Vagrant Cloud  Uploads all built boxes

publish: ## Vagrant Cloud  make uploaded boxes public
	@curl --silent --header "Authorization: Bearer ${VAGRANT_CLOUD_TOKEN}" \
		$(VAGRANT_REPO)/version/$(VERSION)/release --request PUT | jq .

.PHONY: test-vmware test-virtualbox test-libvirt
test-vmware: $(BOXDIR)/vmware/$(NV).vmware.box ## Smoke Testing  VMware
	@vagrant box add --name clear-test --provider vmware_desktop $(BOXDIR)/vmware/$(NV).vmware.box --force
	@pushd extras/test;                                                                            \
	vagrant up --provider vmware_desktop ;                                                        \
	vagrant ssh -c "w; sudo swupd info" && echo "- VMware box (v$(VERSION)) looks OK" || exit 1; \
	vagrant halt -f ;                                                                           \
	vagrant destroy -f;                                                                        \
	vagrant box remove clear-test --provider vmware_desktop;                                 \
	popd

test-virtualbox: $(BOXDIR)/virtualbox/$(NV).virtualbox.box ## Smoke Testing  VirtualBox
	@vagrant box add --name clear-test --provider virtualbox $(BOXDIR)/virtualbox/$(NV).virtualbox.box --force
	@pushd extras/test;                                                                                \
	vagrant up --provider virtualbox ;                                                                \
	vagrant ssh -c "w; sudo swupd info" && echo "- Virtualbox box (v$(VERSION)) looks OK" || exit 1; \
	vagrant halt -f ;                                                                               \
	vagrant destroy -f;                                                                            \
	vagrant box remove clear-test --provider virtualbox;                                          \
	popd

test-libvirt: $(BOXDIR)/libvirt/$(NV).libvirt.box ## Smoke Testing  LibVirt
	@vagrant box add --name clear-test --provider libvirt $(BOXDIR)/libvirt/$(NV).libvirt.box --force
	@pushd extras/test;                                                                             \
	vagrant up --provider libvirt ;                                                                \
	vagrant ssh -c "w; sudo swupd info" && echo "- Libvirt box (v$(VERSION)) looks OK" || exit 1; \
	vagrant halt -f ;                                                                            \
	vagrant destroy -f;                                                                         \
	vagrant box remove clear-test --provider libvirt;                                          \
	popd
	ssh clear@libvirt-host.clearlinux.local "sudo virsh vol-delete clear-test_vagrant_box_image_0.img default"

.PHONY: clean
clean: # does what it says ...
	rm -rf $(MEDIADIR)/* $(BOXDIR)/* packer_cache


