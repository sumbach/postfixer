# What is Postfixer?

Postfixer is a configurable collection of [Capistrano][Capistrano] tasks to assist you in installing and configuring Postfix.

# Why do I need it?

Out of the box, [Postfix][Postfix] is not configured to deliver your application's outgoing email properly:

* Email will be sent from a local hostname (application@hostname.example.com) instead of the appropriate domain address (email@example.com).
* Email to local users (such as error messages from cron) will never by delivered.
* Email is likely to be marked as spam by recipients since it will not be cryptographically signed.

Postfixer will help you get Postfix configured and set up [SPF (Sender Policy Framework)][SPF], [DKIM (DomainKeys Identified Mail)][DKIM], and [ADSP (Author Domain Signing Practices)][ADSP] for your domain.

# Why are my emails being marked as SPAM?

There are several common reasons your outgoing email may be marked as spam

__Problem__: The server IP is on a [blacklist][DNSBL Lookup] of known spam servers.

* __Solution__: Don't send spam!  Secure your mail transfer agent to ensure it's not being used to relay spam.
* __Solution__: Follow up with the blacklist maintainers to have your IP address removed from their listing.

__Problem__: DNS configuration checks fail

* __Solution__: If you use 192.168.1.1 to send email from hostname.example.com, ensure that a reverse DNS lookup for 192.168.1.1 returns hostname.example.com
* __Solution__: Set up the appropriate SPF entries in DNS
* __Solution__: Use DKIM to validate that the email server is being run by the domain's owner

__Problem__: Aggressive spam filters still flag your messages since they haven't whitelisted you yet

* __Solution__: ?

__Problem__: All of the above

* __Solution__: Use a dedicated (for pay) email delivery service such as [SendGrid][SendGrid], [AuthSMTP][AuthSMTP], [Postmark][Postmark], [Amazon SES][Amazon SES], or [SocketLabs][SocketLabs]
* __Solution__: Deploy to Heroku and use the [Sendgrid Add-on][Heroku Sendgrid Add-on]. It requires no configuration and the free edition delivers up to 200 emails per day.


Check out this [awesome blog entry from SendGrid](http://blog.sendgrid.com/10-tips-to-keep-email-out-of-the-spam-folder/) for more ideas

# How to use

## Install Dependencies

    bundle install

## Set up Postfixer configuration for your server

Copy the default config:

    cp config-hostname.example.com.yml config-mysever.mydomain.com.yml

Update your config in config-mysever.mydomain.com.yml:

* __canonical\_hostname__: Fully-qualified domain name (FQDN) for your application server
* __additional\_hostnames__: Any additional hostnames that this server is known by
* __email\_domains__: All domains for which this server should be able to send email
* __forwarding\_address__: Email address for local messages (such as errors from cron jobs)
  * NOTE: This address should be in one of email\_domains
* __envelope\_sender__: SMTP envelope sender (where bounce messages end up)
  * This may be a black hole
  * NOTE: This address should be in one of email\_domains
* __application\_user__: Local user account under which your application runs
  * Emails addressed to this account will be sent to forwarding\_address
* __sudo\_user__: Local user account with root sudo permissions
* __address__: FQDN or IP address used to SSH into this server

## Install and Configure Postfix

Set the CONFIG environment variable to the name of the config

    export CONFIG=mysever.mydomain.com
    cap email:install_packages
    cap email:backup_config
    cap email:generate_config
    cap email:install_config
    cap email:restart

## Set up DNS entries for SPF and DKIM

Generate the DNS entries:

    cap email:print_dns

The output is in BIND zone file format.  You will need to add the entries to your domain where it is hosted--this is often your hosting provider (e.g., slicehost.com) or your domain registrar (e.g., godaddy.com).

# Testing your configuration

## Check your DNS entries

Ensure that DNS entries for canonical_hostname are set properly:

    cap email:check_dns

You may also want to run these validators:

* [DNS Validation][DNS Validation]: awesome tool, clearly lists problems and corrective actions
* [DomainKey Policy Record Tester][DomainKey Policy Record Tester]

## Ensure outgoing email is properly signed and passing SPAM filters

Send a test email to the [port25 verifier][port25 verifier].  In response, the verifier sends a message verifying the

    cap email:send_test_email

# Limitations

* Postfixer has only been tested on Ubuntu servers
  * It _should_ work on any Debian-based distribution
  * RedHat users: patches welcome
  * Even if you're running an unsupported distribution, you can still use generate\_config, print\_dns, check\_dns and send\_test\_email
* Postfixer assumes you're using Postfix as your [MTA][Message transfer agent]
  * If you're using another MTA (such as [Exim][Exim] or [Sendmail][Sendmail]), the same concepts apply, but you'll ned to work out the configuration details
  * Note: Postfixer is only concerned with the MTA used to send email from an application server.  You can use Postfix on application servers while using a different MTA and [MDA][Message delivery agent] on the mail exchangers for your domain.
* Posfixer does not (yet) support [Yahoo DomainKeys][Yahoo DomainKeys]
  * It does support the newer [DKIM (DomainKeys Identified Mail)][DKIM] standard which has largely displaced Yahoo's legacy solution.
* The DNS report assumes you're using Google Apps (who isn't?)
  * If you're using your ISP's or your own incoming mail server, replace "include:\_spf.google.com" in the [SPF][SPF] records with something appropriate to your setup
* Postfixer does not (yet) check if your server is on a [blacklist][DNSBL]
  * I recommend the awesome [DNSBL Lookup][DNSBL Lookup] tool from mxtoolbox.com
  * If your server is on a blacklist, you'll need to request to be removed (the process should be available on the blacklist provider's web site)
* Postfixer does not check for general DNS issues
  * but I recommend [DNS Validation][DNS Validation]

# Contributing

* Please report bugs and feature requests in [Github issues][Github issues]
* [Pull requests][Pull requests] and patches welcome!

# License

Postfixer is released under the MIT license.  See LICENSE for details.


[Capistrano]: https://github.com/capistrano/capistrano/wiki
[Postfix]: http://www.postfix.org/
[SPF]: http://www.openspf.org/
[DKIM]: http://www.dkim.org/
[ADSP]: http://en.wikipedia.org/wiki/Author_Domain_Signing_Practices
[DNSBL]: http://en.wikipedia.org/wiki/DNSBL "DNSBL (DNS Blackhole List)"
[DNSBL Lookup]: http://www.mxtoolbox.com/blacklists.aspx
[SendGrid]: http://sendgrid.com/
[AuthSMTP]: http://www.authsmtp.com/
[Postmark]: http://postmarkapp.com/
[Amazon SES]: http://aws.amazon.com/ses/
[SocketLabs]: http://socketlabs.com/
[Heroku Sendgrid Add-on]: http://addons.heroku.com/sendgrid
[DNS Validation]: http://www.dnsvalidation.com/
[DomainKey Policy Record Tester]: http://domainkeys.sourceforge.net/policycheck.html
[port25 verifier]: http://www.port25.com/domainkeys/
[Message transfer agent]: http://wikipedia.org/wiki/Message_transfer_agent
[Exim]: http://www.exim.org/
[Sendmail]: http://www.sendmail.org/
[Message delivery agent]: http://wikipedia.org/wiki/Mail_Delivery_Agent
[Yahoo DomainKeys]: http://antispam.yahoo.com/domainkeys
[Github issues]: http://github.com/sumbach/postfixer/issues
[Pull requests]: http://help.github.com/pull-requests/

[SMTP Tarpits]: http://en.wikipedia.org/wiki/Tarpit_%28networking%29#SMTP_tarpits
[Postfix configuration]: http://www.postfix.org/documentation.html
[DKIM-milter]: http://www.sendmail.com/sm/wp/dkim/
[DKIM-milter configuration]: http://www.elandsys.com/resources/sendmail/dkim.html
