class FixRepoFieldSequencebyRepo
    attr_accessor :subject
    def initialize(repo, create_tmp_table = true)
      @subject = repo
      @create_tmp_table = create_tmp_table
    end
    def cascade
      if @create_tmp_table
        ## Prepare tmp table
        puts 'Cleaning repo_field_sequences_tmp table'
        clean_repo_field_sequences_tmp
        puts 'repo_field_sequences_tmp table was cleaned'
        puts 'Populating repo_field_sequences_tmp table'
        populate_repo_field_sequences_tmp
        puts 'repo_field_sequences_tmp table was populated'
        ## Recreate all sequences of the Repo
        puts 'Destroying all repo\'s repo_field_sequences'
        ids = subject.repo_field_sequences.ids
        RepoFieldSequence.where(id: ids).delete_all
        puts 'repo_field_sequences were destroyed'
        puts 'Creating repo_field_sequences'
        create_repo_field_sequence
        puts 'repo_field_sequences were created'
      end
      # Clean jobs with error of the Repo
      puts 'Cleaning the sidekiq retry jobs'
      clean_sidekiq_retry_jobs
      puts 'Sidekiq retry jobs were cleaned'
      # Reindex All Cards
      puts 'Reindexing all repo\'s cards'
      reindex_all_cards
      puts 'All repo\'s cards were reindexed'
      # Update Report filters
      puts 'Updating repo\'s filters'
      update_filters if @create_tmp_table
      puts 'Repo\'s filters were updated'
      # Clean cache
      puts 'Cleaning repo\'s cache'
      clean_cache
      puts 'Repo\'s cache was cleaned'
    end
    def clean_repo_field_sequences_tmp
      ActiveRecord::Base.connection.execute "TRUNCATE table repo_field_sequences_tmp;"
    end
    def populate_repo_field_sequences_tmp
      ActiveRecord::Base.connection.execute(<<-SQL)
        INSERT INTO repo_field_sequences_tmp (
          SELECT *
          FROM repo_field_sequences
          WHERE repo_id = #{subject.id}
        );
      SQL
    end
    def get_field_id_by_sequence(sequence)
      ActiveRecord::Base.connection.execute(<<-SQL)
        SELECT field_id
        FROM repo_field_sequences_tmp
        WHERE sequence_number = #{sequence};
      SQL
    end
    def create_repo_field_sequence
      subject.fields.each do |field|
        RepoFieldSequence.create(repo_id: field.repo_id, field_id: field.id, field_type: field.type.format_type)
      end
      subject.fields.deleted.each do |field|
        RepoFieldSequence.create(repo_id: field.repo_id, field_id: field.id, field_type: field.type.format_type)
      end
    end
    def update_filters
      errors = []
      should_migrate = false
      subject.reports.each do |report|
        begin
          filter = report.filter.compact.each_with_object([]) do |filter, new_filter|
            old_sequence = filter['field'].scan(/field_\d+/)&.first&.scan(/\d+/)&.first&.to_i
            if old_sequence.present?
              field_id = get_field_id_by_sequence(old_sequence)&.first['field_id'];
              field = Field.with_deleted.find(field_id)
              filter['field'] = generate_field_name(field)
              should_migrate = true
            end
            puts filter
            new_filter << filter
          end
          report.update!(filter: filter) if should_migrate
        rescue StandardError => error
          errors << { report_id: report.id, error: error.to_s, backtrace: error.backtrace.join("\n") }
          puts errors
          next
        end
      end
    end
    def clean_sidekiq_retry_jobs
      ids = subject.cards.not_draft.map(&:id)
      Sidekiq::RetrySet.new.each do |job|
        job.delete if job.klass == 'CardDenormalizerWorker' && ids.include?(job.args.first)
      end
    end
    def reindex_all_cards(last_id = nil)
      cards = subject.cards.not_draft.order(:id)
      cards = cards.where('id > ?', last_id) if last_id
      cards.find_each do |card|
        card.queue_denormalized_data
        puts "id: #{card.id}"
      end
    end
    def clean_cache
      ::Cache::PipeInvalidatorWorker.perform_async(subject.id)
    end
    def generate_field_name(field)
      sequence_number = field&.repo_field_sequence&.sequence_number
      "field_#{sequence_number}_#{field.type.format_type}" if field.present?
    end
  end