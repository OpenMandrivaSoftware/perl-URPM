%define name perl-URPM
%define real_name URPM
%define release 1mdk

%{expand:%%define version %(perl -ne '/VERSION\s+=[^0-9\.]*([0-9\.]+)/ and print "$1\n"' URPM.pm)}

Packager:       François Pons <fpons@mandrakesoft.com>
Summary:	URPM module for perl
Name:		%{name}
Version:	%{version}
Release:	%{release}
License:	GPL or Artistic
Group:		Development/Perl
Distribution:	Mandrake Linux
Source:		%{real_name}-%{version}.tar.bz2
Prefix:		%{_prefix}
BuildRequires:	perl-devel
BuildRoot:	%{_tmppath}/%{name}-buildroot
Requires:	perl >= 5.601

%description
The URPM module allows you to manipulate rpm files, rpm header files and
hdlist files and manage them in memory.

%prep
%setup -q -n %{real_name}-%{version}

%build
%{__perl} Makefile.PL PREFIX=%{prefix}
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
#%{_libdir}/perl5/man/man3
%{perl_sitearch}/URPM.pm
%{perl_sitearch}/URPM
%{perl_sitearch}/auto/URPM


%changelog
* Fri May 31 2002 François Pons <fpons@mandrakesoft.com> 0.01-1mdk
- initial revision.
