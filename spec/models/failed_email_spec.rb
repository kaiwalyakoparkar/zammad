# Copyright (C) 2012-2024 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe FailedEmail, type: :model do
  subject(:instance) { create(:failed_email) }

  describe '#parsing_error' do
    it 'sets parsing error' do
      instance.parsing_error = 'text'

      expect(instance).to have_attributes(parsing_error: 'text')
    end

    it 'sets parsing error off error' do
      instance.parsing_error = StandardError.new('Sample error')

      expect(instance).to have_attributes(parsing_error: include('Sample error'))
    end
  end

  describe '.by_filepath' do
    let!(:failed_email) { create(:failed_email) }

    it 'finds the email by filename' do
      expect(described_class.by_filepath("some/folder/#{failed_email.id}.eml")).to eq(failed_email)
    end

    it 'finds the email by id' do
      expect(described_class.by_filepath(failed_email.id.to_s)).to eq(failed_email)
    end

    it 'does not find with another extension' do
      expect(described_class.by_filepath("some/folder/#{failed_email.id}.yml")).to be_nil
    end

    it 'does not find if not existant' do
      expect(described_class.by_filepath('1337.eml')).to be_nil
    end
  end

  describe '#reprocess' do
    context 'when it succeeds' do
      it 'destroys entry' do
        instance.reprocess

        expect(instance).to be_destroyed
      end

      it 'creates a ticket' do
        ticket = instance.reprocess

        expect(ticket.articles.first).to have_attributes(
          body: 'Some Text'
        )
      end
    end

    context 'when it fails' do
      before do
        allow_any_instance_of(Channel::EmailParser)
          .to receive(:process_with_timeout)
          .and_return([])
      end

      it 'increases retries count on failure' do
        expect { instance.reprocess }
          .to change(instance, :retries).by(1)
      end

      it 'does not create a ticket' do
        expect { instance.reprocess }.not_to change(Ticket, :count)
      end
    end
  end

  describe '.reprocess_all' do
    let!(:failed_email) { create(:failed_email, data: 'not a mail') }
    let!(:failed_but_correct_email) { create(:failed_email, data: "From: me\nTo: you\nSubject: Hi\n\ntest") }

    before do
      failed_email
      failed_but_correct_email
    end

    it 'creates one ticket for the parseable mail and keeps the other' do
      expect { described_class.reprocess_all }
        .to change(Ticket, :count).by(1)
        .and(change(described_class, :count).by(-1))
    end

    it 'returns a list of processed email files' do
      expect(described_class.reprocess_all).to eq(["#{failed_but_correct_email.id}.eml"])
    end
  end

  describe '.export_all' do
    it 'calls export with all records' do
      instance

      allow_any_instance_of(described_class)
        .to receive(:export)
        .with('path')
        .and_return('path/file.eml')

      expect(described_class.export_all('path'))
        .to contain_exactly('path/file.eml')
    end
  end

  describe '#export' do
    it 'creates a file' do
      path = instance.export

      expect(File.binread(path)).to eq(instance.data)
    end
  end

  describe '.import_all' do
    it 'calls import with all files' do
      path = described_class.generate_path
      instance.export(path)

      allow(described_class)
        .to receive(:import)
        .with(path.join("#{instance.id}.eml"))
        .and_return('imported_path')

      expect(described_class.import_all(path))
        .to contain_exactly('imported_path')
    end
  end

  describe '.import' do
    let(:path)        { described_class.generate_path }
    let(:file_path)   { instance.export(path) }
    let(:sample_text) { Faker::Lorem.sentence }

    context 'with changed content' do
      before { File.binwrite(file_path, sample_text) }

      it 'returns file path for imported file' do
        expect(described_class.import(path.join("#{instance.id}.eml")))
          .to eq(file_path)
      end

      it 'updates record with content of the file' do
        described_class.import(path.join("#{instance.id}.eml"))

        expect(instance.reload).to have_attributes(
          data:          sample_text,
          parsing_error: be_nil
        )
      end
    end

    it 'returns nil if database row does not exist' do
      expect(described_class.import('tmp/1337.eml')).to be_nil
    end

    it 'returns nil if database content matches file content' do
      file_path

      expect(described_class.import(path.join("#{instance.id}.eml")))
        .to be_nil
    end
  end
end
