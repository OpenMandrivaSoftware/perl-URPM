%define name perl-URPM
%define real_name URPM
%define version 0.70
%define release 3mdk

%{expand:%%define rpm_version %(rpm -q --queryformat '%{VERSION}-%{RELEASE}' rpm)}

Packager:       François Pons <fpons@mandrakesoft.com>
Summary:	URPM module for perl
Name:		%{name}
Version:	%{version}
Release:	%{release}
License:	GPL or Artistic
Group:		Development/Perl
Distribution:	Mandrake Linux
Source:		%{real_name}-%{version}.tar.bz2
URL:		http://cvs.mandrakesoft.com/cgi-bin/cvsweb.cgi/soft/perl-URPM
Prefix:		%{_prefix}
BuildRequires:	perl-devel rpm-devel >= 4.0.3 bzip2-devel gcc
Requires:	rpm >= %{rpm_version}, bzip2 >= 1.0
BuildRoot:	%{_tmppath}/%{name}-buildroot

%description
The URPM module allows you to manipulate rpm files, rpm header files and
hdlist files and manage them in memory.

%prep
%setup -q -n %{real_name}-%{version}

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor PREFIX=%{prefix}
make OPTIMIZE="$RPM_OPT_FLAGS" PREFIX=%{prefix}
make test

%install
rm -rf $RPM_BUILD_ROOT
%makeinstall PREFIX=$RPM_BUILD_ROOT%{prefix}

%clean 
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root)
%doc README
#%{_mandir}/man3pm/*
%{perl_vendorarch}/URPM.pm
%{perl_vendorarch}/URPM
%{perl_vendorarch}/auto/URPM


%changelog
* Wed Aug 28 2002 François Pons <fpons@mandrakesoft.com> 0.70-3mdk
- setup state to know if an old package will be upgraded.
- added optional parameter to keep all tags from an rpm.
- added URPM::Package::changelog_* method.

* Mon Aug 26 2002 François Pons <fpons@mandrakesoft.com> 0.70-2mdk
- added more flags to URPM::Transaction::run (oldpackage, test).
- fixed choices to prefer right locales dependent packages.
- added avoided hash to avoid mixing choices when a lot of
  possible packages are available and split have been done
  (openjade bug reported on cooker).

* Fri Aug 23 2002 François Pons <fpons@mandrakesoft.com> 0.70-1mdk
- fixed search method to work correctly.

* Tue Aug 13 2002 François Pons <fpons@mandrakesoft.com> 0.60-8mdk
- fixed request_packages_to_upgrade no more working correctly.

* Mon Aug 12 2002 François Pons <fpons@mandrakesoft.com> 0.60-7mdk
- fixed bad behaviour of request_packages_to_upgrade if upgrade flag
  has been computed before.
- fixed propable old package (according provides) requested by
  request_packages_to_upgrade.

* Mon Aug 12 2002 François Pons <fpons@mandrakesoft.com> 0.60-6mdk
- simplified compute_installed_flags return value (used by DrakX).

* Fri Aug  9 2002 François Pons <fpons@mandrakesoft.com> 0.60-5mdk
- fixed package not selected to be upgraded (--auto-select of
  urpmi) when there are sense conflicts (initscripts).

* Fri Aug  9 2002 François Pons <fpons@mandrakesoft.com> 0.60-4mdk
- compute_installed_flags returns size of package present.
- fixed too large ask_remove closure due to missing provides of
  package.

* Wed Aug  7 2002 François Pons <fpons@mandrakesoft.com> 0.60-3mdk
- added read_config_files and verify_rpm methods.

* Tue Aug  6 2002 François Pons <fpons@mandrakesoft.com> 0.60-2mdk
- fixed typo on diff provides resolved (unable to search requiring
  packages if a sense was given).
- fixed unecessary choices asked to user.

* Mon Aug  5 2002 François Pons <fpons@mandrakesoft.com> 0.60-1mdk
- ask_remove list of package now reference id instead of pkg.
- removed conflicts state not used.
- fixed ask_unselect not taken into account if two successive
  requested resolution.
- ask_remove is now cleaned on unrequested resolution.
- avoid selecting conflicting packages when resolving packages
  to upgrade (--auto-select).
- use perl multi-threaded.

* Thu Jul 25 2002 François Pons <fpons@mandrakesoft.com> 0.50-6mdk
- fixed incomplete search of best requested packages.

* Thu Jul 25 2002 François Pons <fpons@mandrakesoft.com> 0.50-5mdk
- fixed stupid error in URPM/Build.pm.

* Wed Jul 24 2002 François Pons <fpons@mandrakesoft.com> 0.50-4mdk
- fixed another best package choice to avoid choosing package too
  early.
- fixed pre-required files not correctly fetched in provides when
  parsing synthesis file.
- fixed bad behaviour of unresolved_provides_clean.

* Wed Jul 24 2002 François Pons <fpons@mandrakesoft.com> 0.50-3mdk
- fixed typo causing difference of provides to be not examined.
- fixed best package as choice to avoid choosing package too early.
- fixed mulitple definition of same package being selected.

* Tue Jul 23 2002 François Pons <fpons@mandrakesoft.com> 0.50-2mdk
- fixed resolve_closure_ask_remove to really closure.
- changed unsatisfied_requires to use options hash.

* Tue Jul 23 2002 François Pons <fpons@mandrakesoft.com> 0.50-1mdk
- changed existing interface for resolve_requested and
  resolve_unrequested having the same signature.
- fixed ask_unselect may containing erroneous id after resolution.

* Tue Jul 23 2002 François Pons <fpons@mandrakesoft.com> 0.20-2mdk
- fixed unrequested code resolution.

* Mon Jul 22 2002 François Pons <fpons@mandrakesoft.com> 0.20-1mdk
- added remove new package if an older package is requested.
- fixed incomplete closure on ask_remove.
- added unrequested code resolution.

* Mon Jul 22 2002 François Pons <fpons@mandrakesoft.com> 0.11-2mdk
- added option translate_message to URPM::Transaction::run.
- fixed missing by package reference on transaction check error.

* Fri Jul 19 2002 François Pons <fpons@mandrakesoft.com> 0.11-1mdk
- added whatconflicts to traverse_tag.
- fixed semantic of flag_available (package installed or selected).

* Tue Jul 16 2002 François Pons <fpons@mandrakesoft.com> 0.10-2mdk
- extended selected and available flag to take care of base flag.
- improved resolve_requested (use keep_state) and delete
  requested key once taken into account.

* Mon Jul 15 2002 François Pons <fpons@mandrakesoft.com> 0.10-1mdk
- added search method for search from name.
- added composite flag_available method (installed or selected).

* Thu Jul 11 2002 François Pons <fpons@mandrakesoft.com> 0.09-2mdk
- fixed ask_unselect computation.
- added clear_state option to relove_requested (rollback state
  modification needed by DrakX).

* Wed Jul 10 2002 François Pons <fpons@mandrakesoft.com> 0.09-1mdk
- changed semantics of some package flags to extend usability and
  simplicity.
- added no_flag_update to resolve_requested to avoid modifying
  requested or required flag directly.
- added closure on ask_remove.
- removed requires on perl (only perl-base should be enough).
- fixed wrong unsatisfied_requires return value whit a given name.

* Tue Jul  9 2002 François Pons <fpons@mandrakesoft.com> 0.08-4mdk
- fixed too many opened files when building hdlist.

* Tue Jul  9 2002 Pixel <pixel@mandrakesoft.com> 0.08-3mdk
- rebuild for perl 5.8.0

* Mon Jul  8 2002 François Pons <fpons@mandrakesoft.com> 0.08-2mdk
- fixed rflags setting (now keep more than one element).
- fixed setting of ask_unselect correctly.

* Mon Jul  8 2002 François Pons <fpons@mandrakesoft.com> 0.08-1mdk
- added transaction flags (equivalence to --force and --ignoreSize).
- simplified some transaction method names.
- added script fd support.

* Fri Jul  5 2002 François Pons <fpons@mandrakesoft.com> 0.07-2mdk
- fixed transaction methods so that install works.

* Thu Jul  4 2002 François Pons <fpons@mandrakesoft.com> 0.07-1mdk
- added transaction methods and URPM::Transaction type (for DrakX).
- obsoleted URPM::DB::open_rw and removed it.

* Wed Jul  3 2002 François Pons <fpons@mandrakesoft.com> 0.06-2mdk
- fixed virtual provides obsoleted by other package (means kernel
  is requested to be installed even if other kernel is installed).

* Wed Jul  3 2002 François Pons <fpons@mandrakesoft.com> 0.06-1mdk
- added header_filename and update_header to URPM::Package.
- added virtual flag selected to URPM::Package.
- added rate and rflags tags to URPM::Package.
- added URPM::DB::rebuild.
- fixed build of hdlist with non standard rpm filename.

* Mon Jul  1 2002 François Pons <fpons@mandrakesoft.com> 0.05-2mdk
- fixed selection of obsoleted package already installed but
  present in depslist.

* Fri Jun 28 2002 François Pons <fpons@mandrakesoft.com> 0.05-1mdk
- fixed ask_remove not to contains arch.
- removed relocate_depslist (obsoleted).

* Wed Jun 26 2002 François Pons <fpons@mandrakesoft.com> 0.04-6mdk
- fixed work around of rpmlib where provides should be at
  left position of rpmRangesOverlap.

* Tue Jun 18 2002 François Pons <fpons@mandrakesoft.com> 0.04-5mdk
- fixed wrong range overlap evaluation (libgcc >= 3.1 and libgcc.so.1).

* Thu Jun 13 2002 François Pons <fpons@mandrakesoft.com> 0.04-4mdk
- fixed too many package selected on --auto-select.

* Thu Jun 13 2002 François Pons <fpons@mandrakesoft.com> 0.04-3mdk
- fixed compare_pkg (invalid arch comparisons sometimes).
- added (still unused) obsolete flag.

* Thu Jun 13 2002 François Pons <fpons@mandrakesoft.com> 0.04-2mdk
- added ranges_overlap method (uses rpmRangesOverlap in rpmlib).
- made Resolve module to be operational (and usable).

* Tue Jun 11 2002 François Pons <fpons@mandrakesoft.com> 0.04-1mdk
- added Resolve.pm file.

* Thu Jun  6 2002 François Pons <fpons@mandrakesoft.com> 0.03-2mdk
- fixed incomplete compare_pkg not taking into account score
  of arch.

* Thu Jun  6 2002 François Pons <fpons@mandrakesoft.com> 0.03-1mdk
- added more flag method to URPM::Package
- avoid garbage output when reading hdlist archive.
- moved id internal reference to bit field of flag.

* Wed Jun  5 2002 François Pons <fpons@mandrakesoft.com> 0.02-3mdk
- removed log on opening/closing rpmdb.
- modified reading of archive to avoid incomplete read.

* Wed Jun  5 2002 François Pons <fpons@mandrakesoft.com> 0.02-2mdk
- added log on opening/closing rpmdb.

* Mon Jun  3 2002 François Pons <fpons@mandrakesoft.com> 0.02-1mdk
- new version with extended parameters list for URPM::Build.
- fixed code to be -w clean.

* Fri May 31 2002 François Pons <fpons@mandrakesoft.com> 0.01-1mdk
- initial revision.
