requires 'perl', '5.022';
requires 'Mojolicious';
requires 'Path::Tiny';
requires 'Syntax::Keyword::Try';
requires 'List::MoreUtils';
requires 'Digest::SHA';
requires 'Net::Statsite::Client';
requires 'failures';
requires 'Safe::Isa';
requires 'Guard', '1.023';
requires 'Mojolicious::Plugin::CHI', '0.09';
requires 'CHI::Driver::Memcached', '0.16';
requires 'Cache::Memcached::Fast', '0.25';


on 'test' => sub {
    requires 'Test::More', '0.98';
    requires 'Test::Exception';
    requires 'Mock::Quick';
    requires 'Test::Mock::Cmd', '0.7';
};

on 'develop' => sub {
    requires 'Minilla';
    requires 'Module::Build::Tiny';
};
