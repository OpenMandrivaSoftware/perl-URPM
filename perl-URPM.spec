%define name perl-URPM
%define real_name URPM
%define version 0.94
%define release 5mdk

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
Provides:	perl(URPM::Build) = %{version}-%{release}
Provides:	perl(URPM::Resolve) = %{version}-%{release}
Provides:	perl(URPM::Signature) = %{version}-%{release}
BuildRoot:	%{_tmppath}/%{name}-%{version}-%{release}-buildroot

%description
The URPM module allows you to manipulate rpm files, rpm header files and
hdlist files and manage them in memory.

%prep
%setup -q -n %{real_name}-%{version}

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
make OPTIMIZE="$RPM_OPT_FLAGS"
#make test

%install
rm -rf $RPM_BUILD_ROOT
%makeinstall_std

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
* Wed Sep 10 2003 François Pons <fpons@mandrakesoft.com> 0.94-5mdk
- fixed bad reference to ARRAY on promote.

* Fri Sep  5 2003 François Pons <fpons@mandrakesoft.com> 0.94-4mdk
- fixed diff provides generation to be always managed when
  requires have been completely handled.

* Tue Sep  2 2003 François Pons <fpons@mandrakesoft.com> 0.94-3mdk
- fixed updating with older package not properly handled.

* Fri Aug 22 2003 François Pons <fpons@mandrakesoft.com> 0.94-2mdk
- fixed potential deadlock on backtrack (use keep on the fly
  algorithm to complete backtracking).

* Thu Aug 21 2003 François Pons <fpons@mandrakesoft.com> 0.94-1mdk
- fix for pubkey name extraction (gc).
- updated code to be more adapted for both urpmi and DrakX
  in URPM::Signature.

* Wed Aug 20 2003 François Pons <fpons@mandrakesoft.com> 0.93-7mdk
- fixed diff provides to be ignored on obsoleted provides which caused
  resolver to choose bad package due to removed obsoleted provides.
- added URPM::Signature::compare_pubkeys to workaround rpm
  importation of key with modified armor.

* Tue Aug 19 2003 François Pons <fpons@mandrakesoft.com> 0.93-6mdk
- make URPM::Signature::import_armored_file independent from rpm.
- added URPM::import_pubkey in xs directly.

* Mon Aug 18 2003 Pixel <pixel@mandrakesoft.com> 0.93-5mdk
- perl_checker compliance

* Wed Aug 13 2003 Guillaume Cottenceau <gc@mandrakesoft.com> 0.93-4mdk
- provide URPM::Signature as well

* Mon Aug 11 2003 François Pons <fpons@mandrakesoft.com> 0.93-3mdk
- fixed limit case for string extraction from headers (files_md5sum).
- removed unsatisfied_requires2 from xs not used and not finished.

* Mon Aug 11 2003 François Pons <fpons@mandrakesoft.com> 0.93-2mdk
- fixed pubkey management, fixed importation of pubkey in rpmdb.

* Wed Aug  6 2003 François Pons <fpons@mandrakesoft.com> 0.93-1mdk
- added URPM::Signature for handling armored gpg file and
  internal rpm pubkey.
- take care of PreReq when building hdlist or synthesis files.
- removed id log during hdlist or synthesis creation.

* Mon Aug  4 2003 François Pons <fpons@mandrakesoft.com> 0.92-4mdk
- sanity check on transaction set (should be the same as
  normal selection, else something wrong has occured).
- updated with newer rpm with obsoletes fixed among others.

* Fri Aug  1 2003 Pixel <pixel@mandrakesoft.com> 0.92-3mdk
- rebuild for new perl (it helps DrakX build script)
- use DESTDIR

* Wed Jul 30 2003 François Pons <fpons@mandrakesoft.com> 0.92-2mdk
- fixed some missing unsatisfied in reason of rejected.
- fixed provide obsoleted which should not be taken into account
  when looking for obsoletes (arts problem).

* Mon Jul 28 2003 François Pons <fpons@mandrakesoft.com> 0.92-1mdk
- added keep option to URPM::resolve_requested to avoid removing
  packages.

* Thu Jul 24 2003 François Pons <fpons@mandrakesoft.com> 0.91-14mdk
- fixed handling of kde packages being splitted with different
  names which obfuscated the resolution algorithm, difference
  of provides are now handled later (fifo).

* Thu Jul 24 2003 François Pons <fpons@mandrakesoft.com> 0.91-13mdk
- modified internal handling of string list to allow complex
  combined method in pure C in order to increase speed.
- added provides_overlap and obsoletes_overlap in XS to implement
  a scalar grep of ranges_overlap on provides or obsoletes.
- fixed a small typo in constant character in ranges_overlap which
  may have caused some strange result.

* Wed Jul 16 2003 François Pons <fpons@mandrakesoft.com> 0.91-12mdk
- fixed typo in regex handling in URPM::compute_flags.
- fixed cache contents not taken into account.

* Thu Jul 10 2003 François Pons <fpons@mandrakesoft.com> 0.91-11mdk
- improved URPM::compute_flags.
- started coding URPM::unsatisfied_requires in XS (as
  URPM::unsatisfied_requires2).

* Mon Jul  7 2003 François Pons <fpons@mandrakesoft.com> 0.91-10mdk
- fixed backtracking not applied on promotion which now ends
  up in removing the initial packages.
- promote and psel are propagated into selected hash.

* Mon Jul  7 2003 François Pons <fpons@mandrakesoft.com> 0.91-9mdk
- fixed provides from package not examined for looking into
  unsatisfied requires.
- fixed handling of promoteepoch (if B requires A and both A and B
  are new packages, promoteepoch can be activated).
- updated comments about promoteepoch management (it is touchy
  enough without adding obfuscation here).
- fixed (a lot of people should be very happy now) global unsatisfied
  requires examined, so that it should now be possible to keep a
  rpmdb with unsatisfied dependencies.

* Fri Jul  4 2003 François Pons <fpons@mandrakesoft.com> 0.91-8mdk
- removed handling of promoteepoch as it is specifically obscure
  in rpm and make urpmi crazy.

* Thu Jun 26 2003 François Pons <fpons@mandrakesoft.com> 0.91-7mdk
- fixed possible transaction set build even for empty selection.
- fixed whatrequires hash abnormally populated (no problem raised).
- added unsatisfied information to selected hash when nodeps option
  is given to URPM::resolve_requested.

* Thu Jun 19 2003 François Pons <fpons@mandrakesoft.com> 0.91-6mdk
- make sure callback options are taken into account only if a
  reference is given.
- make sure URPM::build_transaction_set do not create empty
  transaction.
- added source of promotion selection.

* Thu Jun 19 2003 François Pons <fpons@mandrakesoft.com> 0.91-5mdk
- added promote to backtrack data for more info.
- fixed visual glitches when a package has its selection backtracked
  whereas it is already installed.

* Wed Jun 18 2003 François Pons <fpons@mandrakesoft.com> 0.91-4mdk
- fixed installation of old package due to missing closure.
- fixed nodeps option to used for building transaction set.
- fixed too many from source propagated which were not legal.
- fixed bad conflicts listing.

* Wed Jun 18 2003 François Pons <fpons@mandrakesoft.com> 0.91-3mdk
- fixed obssoletes on virtual provides not taken into account.
- fixed option name given to URPM::build_transaction_set.
- fixed missing closure on rejected (first one).
- fixed bad disable closure on rejected.

* Tue Jun 17 2003 François Pons <fpons@mandrakesoft.com> 0.91-2mdk
- fixed promotion of epoch to be rpm 4.2 compliant :
   - added promotion boolean to URPM::ranges_overlap.
   - changed URPM::find_candidate_packages interface.
- fixed compilation on old rpm-4.0.4.

* Mon Jun 16 2003 François Pons <fpons@mandrakesoft.com> 0.91-1mdk
- added transaction set methods.
- added disable_obsolete flags to improve installation mode of
  packages, now handled by resolve_requested.
- obsoleted URPM::compute_skip_flags (now URPM::compute_flags).
- fixed rpmdb.t test when gpg pubkey has been imported in rpmdb.

* Thu Jun 12 2003 François Pons <fpons@mandrakesoft.com> 0.90-10mdk
- changed return value of verify_rpm to allow looking at key id.

* Wed Jun 11 2003 François Pons <fpons@mandrakesoft.com> 0.90-9mdk
- fixed problem in disable_selected (ordering of operations).

* Thu Jun  5 2003 François Pons <fpons@mandrakesoft.com> 0.90-8mdk
- cleaned code to be more perl portable.
- fixed severe bug on perl stack manipulation when using callback.
- fixed order return value.

* Thu Jun  5 2003 François Pons <fpons@mandrakesoft.com> 0.90-7mdk
- no_flag_update is no more used.
- added clever cache management when building headers.
- fixed disable_selected_unrequested_dependencies.
- fixed packages still required when their root requested
  was deselected (option keep_unrequested_dependencies not set).
- fixed too early closure of rejected package when an older one
  was selected.
- fixed some reasons of removing packages to be lost.

* Tue Jun 03 2003 Warly <warly@mandrakesoft.com> 0.90-6mdk
- add Pkg_buildtime to get RPMTAG_BUILDTIME

* Tue Jun  3 2003 François Pons <fpons@mandrakesoft.com> 0.90-5mdk
- fixed typo in parse_rpm method.

* Mon Jun  2 2003 François Pons <fpons@mandrakesoft.com> 0.90-4mdk
- added an option to disable unrequested dependencies when
  backtracking a selection.
- added an option to avoid deselecting package with broken
  dependencies.
- simplified update_header and parse_rpm methods.
- cleaned XS code.

* Wed May 28 2003 Warly <warly@mandrakesoft.com> 0.90-3mdk
- add license function for urpm->{depslist}[$id]
- fix Urpm_parse_rpm argument initialization (sytematically setting packing and keep_all_tags to zero)

* Mon May 26 2003 François Pons <fpons@mandrakesoft.com> 0.90-2mdk
- fixed URPM::resolve_requested return value (list of package
  selected by this call).
- fixed backtrack reason to be stored in rejected hash (so that
  urpmi can say why a package is not selected).

* Fri May 23 2003 François Pons <fpons@mandrakesoft.com> 0.90-1mdk
- extended URPM::search with newer/modified options.
- fixed URPM::Package::compare_pkg to work with identical
  arguments.
- modified requested flag sense (now indicates a wish for
  a requested package but not necessary required or selected).
- obsoleted URPM::resolve_closure_ask_remove by
  URPM::resolve_rejected which compute closures on installed
  packages (used for obsoleted and removed resolution).
- obsoleted URPM::resolve_unrequested by URPM::disable_selected
  which is faster and simpler to invoke.
- newer method have been defined, much notably handle backtrack.
- keep_state is no more used for URPM::resolve_requested.
- obsoleted, ask_remove, ask_unselect have been obsoleted by
  rejected and backtrack facility in state.
- avoid returning number of transaction run problems.
- added compatiblity method to avoid breaking urpmi, rpmdrake and
  DrakX completely (though there could be some strange results).

* Fri May 16 2003 François Pons <fpons@mandrakesoft.com> 0.84-1mdk
- removed provided hash from state and added use_sense value to
  provides hash values when using sense.
- removed installed hash from state and added cached_installed
  which is no more updated and cached installed provides without
  sense associated.
- allow removing of package by giving the fullname (with arch).
- changed ask_remove hash keys to be fullname compliant.
- light improvement of speed (10%% faster on dependencies
  computation) and memory usage (provided hashes removed).

* Wed May 14 2003 François Pons <fpons@mandrakesoft.com> 0.83-4mdk
- completed URPM::Transaction::verify_rpm for signature checking
  and added a lot of more options (including db to avoid openning
  new transaction and new database (rpm 4.2 behaviour)).

* Tue May 13 2003 Pons François <fpons@mandrakesoft.com> 0.83-3mdk
- fixed URPM::Transaction::check and URPM::Transaction::run
  when returning error list.

* Mon May 12 2003 Guillaume Cottenceau <gc@mandrakesoft.com> 0.83-2mdk
- rebuild for new perl requires/provides
- provide perl packages URPM::Resolve and URPM::Build since the
  perl packages are URPM for object export

* Tue Apr 29 2003 François Pons <fpons@mandrakesoft.com> 0.83-1mdk
- added preliminary support for rpm 4.2, there is lack of
  signature checking but interface of URPM is kept.

* Thu Apr 24 2003 François Pons <fpons@mandrakesoft.com> 0.82-4mdk
- intergrated another patch from Olivier Thauvin to add method
  for manipulating source rpm to URPM::Package (buildarchs,
  excludearchs, exclusivearchs).

* Tue Apr 22 2003 François Pons <fpons@mandrakesoft.com> 0.82-3mdk
- integrated patch from Olivier Thauvin to add misc method to
  URPM::Package (packager, buildhost, url).

* Mon Apr 14 2003 François Pons <fpons@mandrakesoft.com> 0.82-2mdk
- fixed skip flag computation.

* Fri Apr 11 2003 François Pons <fpons@mandrakesoft.com> 0.82-1mdk
- added flag skip for each package, added URPM::Package::flag_skip
  and URPM::Package::set_flag_skip as well as compute_skip_flags.
- added excludedocs parameter for transaction.
- reduced maximal number of packages supported to a little more
  than 1 million (instead of 2 millions previously).
- fixed possible core dumps when string rpm tag are not present.

* Wed Mar 12 2003 François Pons <fpons@mandrakesoft.com> 0.81-13mdk
- fixed bug 3207 (consolidated avoided hash with removed and
  conflicting packages).

* Mon Mar 10 2003 François Pons <fpons@mandrakesoft.com> 0.81-12mdk
- fixed typo in search method.
- fixed wrong resolution of conflicts where an older package
  may be used whereas only a newer one should be tested.
- make it somewhat perl_checker clean.

* Mon Mar  3 2003 François Pons <fpons@mandrakesoft.com> 0.81-11mdk
- fixed duplicated filehandle not with close-on-exec flag
  which caused removable device to be locked on some case
  using urpmi.

* Thu Feb 27 2003 François Pons <fpons@mandrakesoft.com> 0.81-10mdk
- allow choices to return mulitple selection.

* Wed Feb 19 2003 François Pons <fpons@mandrakesoft.com> 0.81-9mdk
- handle titi sucks on libalsa2 which obsoletes itself.

* Thu Feb 13 2003 François Pons <fpons@mandrakesoft.com> 0.81-8mdk
- fixed compute_installed_flags to take of compatible arch.

* Thu Jan 23 2003 François Pons <fpons@mandrakesoft.com> 0.81-7mdk
- fixed unsatisfied requires of already selected package to
  an installed properties which is removed later.
- simplified weight propagation when building depslist (ordering).

* Mon Jan  6 2003 François Pons <fpons@mandrakesoft.com> 0.81-6mdk
- fixed avoiding package with virtual provides obsoleted by
  another package as this is not a true obsoletes (openssh).

* Mon Jan  6 2003 François Pons <fpons@mandrakesoft.com> 0.81-5mdk
- fixed bad filename generation (cause problem to genhdlist if
  renamed packages are existing).

* Fri Dec 20 2002 Pixel <pixel@mandrakesoft.com> 0.81-4mdk
- perl_checker fixes (syntax only)

* Wed Dec 18 2002 Pixel <pixel@mandrakesoft.com> 0.81-3mdk
- help perl_checker recognise packages used as classes

* Wed Dec 18 2002 Pixel <pixel@mandrakesoft.com> 0.81-2mdk
- perl_checker fixes

* Tue Dec 17 2002 François Pons <fpons@mandrakesoft.com> 0.81-1mdk
- little improve on traverse_tag with tag name whit --env.
- big improve on traverse_tag with tag whatrequires and
  whatconflicts with --env.
- fixed dependencies resolution when various different version
  of a package are available.

* Wed Dec 11 2002 François Pons <fpons@mandrakesoft.com> 0.80-2mdk
- removed dSP in XS (sound like perl doesn't like them a lot),
  this fixes urpmf problem of reading first hdlist.

* Thu Dec  5 2002 François Pons <fpons@mandrakesoft.com> 0.80-1mdk
- added %%options for parse_(hdlist|synthesis|rpm) to support
  callback (for urpmf in perl).
- added summary in synthesis when parsing (for urpmf --summary
  with synthesis).

* Tue Dec  3 2002 François Pons <fpons@mandrakesoft.com> 0.71-1mdk
- added options to URPM::Transaction::add to handle excludepath
  option of rpm.

* Tue Sep 17 2002 François Pons <fpons@mandrakesoft.com> 0.70-10mdk
- fixed some packages which may not be upgraded on call to
  request_packages_to_upgrade according to packages in depslist.

* Mon Sep  9 2002 François Pons <fpons@mandrakesoft.com> 0.70-9mdk
- select package already installed to be taken instead of proposing
  choice to the user.
- fixed bad test for first package of first synthesis to be chosen
  to be upgraded.

* Mon Sep  2 2002 François Pons <fpons@mandrakesoft.com> 0.70-8mdk
- added start and end options to request_packages_to_upgrade
  for DrakX to choose updated packages to upgrade.

* Fri Aug 30 2002 François Pons <fpons@mandrakesoft.com> 0.70-7mdk
- fixed the fix of split of package (5mdk).

* Fri Aug 30 2002 François Pons <fpons@mandrakesoft.com> 0.70-6mdk
- improved URPM::resolve_closure_ask_remove to keep track of
  removal path and size of package being removed.

* Thu Aug 29 2002 François Pons <fpons@mandrakesoft.com> 0.70-5mdk
- fixed split of package that could lead to excesive number of
  package proposed to be removed.

* Thu Aug 29 2002 François Pons <fpons@mandrakesoft.com> 0.70-4mdk
- fixed requires examination for right locales.

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
